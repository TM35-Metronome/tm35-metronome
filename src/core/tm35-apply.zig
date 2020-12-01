const clap = @import("clap");
const std = @import("std");
const util = @import("util");

const common = @import("common.zig");
const gen3 = @import("gen3.zig");
const gen4 = @import("gen4.zig");
const gen5 = @import("gen5.zig");
const rom = @import("rom.zig");

const builtin = std.builtin;
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;

const path = fs.path;

const gba = rom.gba;
const nds = rom.nds;

const bit = util.bit;
const escape = util.escape;
const exit = util.exit;
const parse = util.parse;

const li16 = rom.int.li16;
const lu16 = rom.int.lu16;
const lu32 = rom.int.lu32;
const lu64 = rom.int.lu64;
const lu128 = rom.int.lu128;

const Param = clap.Param(clap.Help);

pub const main = util.generateMain("0.0.0", main2, &params, usage);

const params = blk: {
    @setEvalBranchQuota(100000);
    break :blk [_]Param{
        clap.parseParam("-a, --abort-on-first-warning  Abort execution on the first warning emitted.                                                         ") catch unreachable,
        clap.parseParam("-h, --help                    Display this help text and exit.                                                                      ") catch unreachable,
        clap.parseParam("-n, --no-output               Don't output the file.                                                                                ") catch unreachable,
        clap.parseParam("-o, --output <FILE>           Override destination path.                                                                            ") catch unreachable,
        clap.parseParam("-p, --patch <none|live|full>  Output patch data to stdout when not 'none'. 'live' = patch after each line. 'full' = patch when done.") catch unreachable,
        clap.parseParam("-r, --replace                 Replace output file if it already exists.                                                             ") catch unreachable,
        clap.parseParam("-v, --version                 Output version information and exit.                                                                  ") catch unreachable,
        clap.parseParam("<ROM>                         The rom to apply the changes to.                                                                  ") catch unreachable,
    };
};

fn usage(writer: anytype) !void {
    try writer.writeAll("Usage: tm35-apply ");
    try clap.usage(writer, &params);
    try writer.writeAll("\nApplies changes to Pokémon roms.\n" ++
        "\n" ++
        "Options:\n");
    try clap.help(writer, &params);
}

const PatchOption = enum {
    none,
    live,
    full,
};

/// TODO: This function actually expects an allocator that owns all the memory allocated, such
///       as ArenaAllocator or FixedBufferAllocator. Can we either make this requirement explicit
///       or move the Arena into this function?
pub fn main2(
    allocator: *mem.Allocator,
    comptime Reader: type,
    comptime Writer: type,
    stdio: util.CustomStdIoStreams(Reader, Writer),
    args: anytype,
) u8 {
    const pos = args.positionals();
    const file_name = if (pos.len > 0) pos[0] else {
        stdio.err.writeAll("No file provided\n") catch {};
        usage(stdio.err) catch {};
        return 1;
    };

    const patch_arg = args.option("--patch") orelse "none";
    const patch = std.meta.stringToEnum(PatchOption, patch_arg) orelse {
        stdio.err.print("--patch does not support '{}'\n", .{patch_arg}) catch {};
        usage(stdio.err) catch {};
        return 1;
    };

    const no_output = args.flag("--no-output");
    const abort_on_first_warning = args.flag("--abort-on-first-warning");
    const replace = args.flag("--replace");
    const out = args.option("--output") orelse blk: {
        const res = fmt.allocPrint(allocator, "{}.modified", .{path.basename(file_name)});
        break :blk res catch |err| return exit.allocErr(stdio.err);
    };

    var nds_rom: nds.Rom = undefined;
    var game: Game = blk: {
        const file = fs.cwd().openFile(file_name, .{}) catch |err| return exit.openErr(stdio.err, file_name, err);
        defer file.close();

        const gen3_error = if (gen3.Game.fromFile(file, allocator)) |game| {
            break :blk Game{ .gen3 = game };
        } else |err| err;

        file.seekTo(0) catch |err| return exit.readErr(stdio.err, file_name, err);
        nds_rom = nds.Rom.fromFile(file, allocator) catch |nds_error| {
            stdio.err.print("Failed to load '{}' as a gen3 game: {}\n", .{ file_name, gen3_error }) catch {};
            stdio.err.print("Failed to load '{}' as a gen4/gen5 game: {}\n", .{ file_name, nds_error }) catch {};
            return 1;
        };

        const gen4_error = if (gen4.Game.fromRom(allocator, &nds_rom)) |game| {
            break :blk Game{ .gen4 = game };
        } else |err| err;

        const gen5_error = if (gen5.Game.fromRom(allocator, &nds_rom)) |game| {
            break :blk Game{ .gen5 = game };
        } else |err| err;

        stdio.err.print("Successfully loaded '{}' as a nds rom.\n", .{file_name}) catch {};
        stdio.err.print("Failed to load '{}' as a gen4 game: {}\n", .{ file_name, gen4_error }) catch {};
        stdio.err.print("Failed to load '{}' as a gen5 game: {}\n", .{ file_name, gen5_error }) catch {};
        return 1;
    };
    defer game.deinit();

    // When --patch is passed, we store a copy of the games old state, so that we
    // can generate binary patches between old and new versions.
    var old_bytes = std.ArrayList(u8).init(allocator);
    defer old_bytes.deinit();
    if (patch != .none)
        old_bytes.appendSlice(game.data()) catch return exit.allocErr(stdio.err);

    var fifo = util.read.Fifo(.Dynamic).init(allocator);
    var line_num: usize = 1;
    while (util.read.line(stdio.in, &fifo) catch |err| return exit.stdinErr(stdio.err, err)) |line| : (line_num += 1) {
        (switch (game) {
            .gen3 => |*gen3_game| applyGen3(gen3_game, line),
            .gen4 => |*gen4_game| applyGen4(gen4_game.*, line),
            .gen5 => |*gen5_game| applyGen5(gen5_game.*, line),
        }) catch |err| {
            stdio.err.print("(stdin):{}:1: warning: {}\n", .{ line_num, @errorName(err) }) catch {};
            stdio.err.print("{}\n", .{line}) catch {};
            if (abort_on_first_warning)
                return 1;
            continue;
        };
        if (patch == .live)
            game.apply() catch return exit.allocErr(stdio.err);

        if (patch == .live) {
            var it = common.PatchIterator{
                .old = old_bytes.items,
                .new = game.data(),
            };
            while (it.next()) |p| {
                stdio.out.print("[{}]={x}\n", .{
                    p.offset,
                    p.replacement,
                }) catch |err| return exit.stdoutErr(stdio.err, err);

                old_bytes.resize(math.max(
                    old_bytes.items.len,
                    p.offset + p.replacement.len,
                )) catch return exit.allocErr(stdio.err);
                common.patch(old_bytes.items, &[_]common.Patch{p});
            }
            stdio.out.context.flush() catch |err| return exit.stdoutErr(stdio.err, err);
        }
    }

    if (patch == .full) {
        var it = common.PatchIterator{
            .old = old_bytes.items,
            .new = game.data(),
        };
        while (it.next()) |p| {
            stdio.out.print("[{}]={x}\n", .{
                p.offset,
                p.replacement,
            }) catch |err| return exit.stdoutErr(stdio.err, err);
        }
    }

    if (no_output)
        return 0;

    const out_file = fs.cwd().createFile(out, .{
        .exclusive = !replace,
        .truncate = false,
    }) catch |err| return exit.createErr(stdio.err, out, err);
    const writer = out_file.writer();

    game.apply() catch |err| return exit.err(stdio.err, "apply error: {}\n", .{err});
    game.write(writer) catch |err| return exit.writeErr(stdio.err, out, err);

    const len = game.data().len;
    out_file.setEndPos(len) catch |err| return exit.writeErr(stdio.err, out, err);

    return 0;
}

const Game = union(enum) {
    gen3: gen3.Game,
    gen4: gen4.Game,
    gen5: gen5.Game,

    pub fn data(game: Game) []const u8 {
        return switch (game) {
            .gen3 => |g| g.data,
            .gen4 => |g| g.rom.data.items,
            .gen5 => |g| g.rom.data.items,
        };
    }

    pub fn apply(game: *Game) !void {
        switch (game.*) {
            .gen3 => |*g| try g.apply(),
            .gen4 => |*g| try g.apply(),
            .gen5 => |*g| try g.apply(),
        }
    }

    pub fn write(game: Game, writer: anytype) !void {
        switch (game) {
            .gen3 => |g| try g.write(writer),
            .gen4 => |g| try g.rom.write(writer),
            .gen5 => |g| try g.rom.write(writer),
        }
    }

    pub fn deinit(game: Game) void {
        switch (game) {
            .gen3 => |g| g.deinit(),
            .gen4 => |g| g.deinit(),
            .gen5 => |g| g.deinit(),
        }
    }
};

const sw = parse.Swhash(16);
const c = sw.case;
const m = sw.match;

pub fn toInt(
    comptime Int: type,
    comptime endian: builtin.Endian,
) fn ([]const u8) ?rom.int.Int(Int, endian) {
    return struct {
        const Res = rom.int.Int(Int, endian);
        fn func(str: []const u8) ?Res {
            const i = parse.toInt(Int, 10)(str) orelse return null;
            return Res.init(i);
        }
    }.func;
}

pub const parseli16v = parse.value(li16, toInt(i16, .Little));
pub const parselu16v = parse.value(lu16, toInt(u16, .Little));
pub const parselu32v = parse.value(lu32, toInt(u32, .Little));
pub const parselu64v = parse.value(lu64, toInt(u64, .Little));

pub const converters = .{
    parse.toBool,
    parse.toEnum(common.EggGroup),
    parse.toEnum(common.EvoMethod),
    parse.toEnum(common.MoveCategory),
    parse.toEnum(gen4.Pocket),
    parse.toEnum(gen5.Evolution.Method),
    parse.toEnum(gen5.Pocket),
    parse.toInt(u1, 10),
    parse.toInt(u2, 10),
    parse.toInt(u4, 10),
    parse.toInt(u7, 10),
    parse.toInt(u8, 10),
    parse.toInt(u9, 10),
    parse.toInt(u16, 10),
    parse.toInt(u32, 10),
    parse.toInt(u64, 10),
    toInt(u16, .Little),
    toInt(u32, .Little),
    toInt(u64, .Little),
};

fn applyGen3(game: *gen3.Game, str: []const u8) !void {
    var parser = parse.MutParser{ .str = str };
    switch (m(try parser.parse(parse.anyField))) {
        c("version") => {
            const value = try parser.parse(comptime parse.enumv(common.Version));
            if (value != game.version)
                return error.VersionDontMatch;
        },
        c("game_title") => {
            const value = try parser.parse(parse.strv);
            if (!mem.eql(u8, value, &game.header.game_title))
                return error.GameTitleDontMatch;
        },
        c("gamecode") => {
            const value = try parser.parse(parse.strv);
            if (!mem.eql(u8, value, &game.header.gamecode))
                return error.GameCodeDontMatch;
        },
        c("starters") => {
            const index = try parser.parse(parse.index);
            const value = try parser.parse(parselu16v);
            if (index >= game.starters.len)
                return error.Error;
            game.starters[index].* = value;
            game.starters_repeat[index].* = value;
        },
        c("text_delays") => {
            const index = try parser.parse(parse.index);
            if (index >= game.text_delays.len)
                return error.Error;
            game.text_delays[index] = try parser.parse(parse.u8v);
        },
        c("trainers") => {
            const index = try parser.parse(parse.index);
            if (index >= game.trainers.len)
                return error.Error;
            const trainer = &game.trainers[index];
            const party = &game.trainer_parties[index];

            const field = try parser.parse(parse.anyField);
            switch (m(field)) {
                c("class") => trainer.class = try parser.parse(parse.u8v),
                c("gender") => trainer.encounter_music.gender = try parser.parse(comptime parse.enumv(gen3.Gender)),
                c("encounter_music") => trainer.encounter_music.music = try parser.parse(parse.u7v),
                c("trainer_picture") => trainer.trainer_picture = try parser.parse(parse.u8v),
                c("is_double") => trainer.is_double = try parser.parse(parselu32v),
                c("party_type") => trainer.party_type = try parser.parse(comptime parse.enumv(gen3.PartyType)),
                c("party_size") => party.size = try parser.parse(parse.u32v),
                c("ai") => trainer.ai = try parser.parse(parselu32v),
                c("name") => try gen3.encodings.encode(.en_us, try parser.parse(parse.strv), &trainer.name),
                c("items") => try parse.anyT(parser.str, &trainer.items, converters),
                c("party") => {
                    const pindex = try parser.parse(parse.index);
                    if (pindex >= party.size)
                        return error.Error;

                    const member = &party.members[pindex];
                    switch (m(try parser.parse(parse.anyField))) {
                        c("iv") => member.base.iv = try parser.parse(parselu16v),
                        c("level") => member.base.level = try parser.parse(parselu16v),
                        c("species") => member.base.species = try parser.parse(parselu16v),
                        c("item") => member.item = try parser.parse(parselu16v),
                        c("moves") => try parse.anyT(parser.str, &member.moves, converters),
                        else => return error.NoField,
                    }
                },
                else => return error.NoField,
            }
        },
        c("pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.pokemons.len)
                return error.Error;
            const pokemon = &game.pokemons[index];

            const field = try parser.parse(parse.anyField);
            switch (m(field)) {
                c("stats") => try parse.anyT(parser.str, &pokemon.stats, converters),
                c("types") => try parse.anyT(parser.str, &pokemon.types, converters),
                c("items") => try parse.anyT(parser.str, &pokemon.items, converters),
                c("abilities") => try parse.anyT(parser.str, &pokemon.abilities, converters),
                c("ev_yield") => try parse.anyT(parser.str, &pokemon.ev_yield, converters),
                c("egg_groups") => try parse.anyT(parser.str, &pokemon.egg_groups, converters),
                c("evos") => try parse.anyT(parser.str, &game.evolutions[index], converters),
                c("catch_rate") => pokemon.catch_rate = try parser.parse(parse.u8v),
                c("base_exp_yield") => pokemon.base_exp_yield = try parser.parse(parse.u8v),
                c("gender_ratio") => pokemon.gender_ratio = try parser.parse(parse.u8v),
                c("egg_cycles") => pokemon.egg_cycles = try parser.parse(parse.u8v),
                c("base_friendship") => pokemon.base_friendship = try parser.parse(parse.u8v),
                c("growth_rate") => pokemon.growth_rate = try parser.parse(comptime parse.enumv(common.GrowthRate)),
                c("safari_zone_rate") => pokemon.safari_zone_rate = try parser.parse(parse.u8v),
                c("color") => pokemon.color.color = try parser.parse(comptime parse.enumv(common.ColorKind)),
                c("flip") => pokemon.color.flip = try parser.parse(parse.boolv),
                c("tms"), c("hms") => {
                    const is_tms = c("tms") == m(field);
                    const tindex = try parser.parse(parse.index);
                    const value = try parser.parse(parse.boolv);
                    const len = if (is_tms) game.tms.len else game.hms.len;
                    if (tindex >= len)
                        return error.Error;

                    const rindex = tindex + game.tms.len * @boolToInt(!is_tms);
                    const learnset = &game.machine_learnsets[index];
                    learnset.* = lu64.init(bit.setTo(u64, learnset.value(), @intCast(u6, rindex), value));
                },
                c("moves") => {
                    const ptr = &game.level_up_learnset_pointers[index];
                    const lvl_up_moves = try ptr.toSliceZ2(game.data, gen3.LevelUpMove.term);
                    try parse.anyT(parser.str, &lvl_up_moves, converters);
                },
                c("name") => {
                    if (index >= game.pokemon_names.len)
                        return error.Error;

                    const new_name = try parser.parse(parse.strv);
                    try gen3.encodings.encode(.en_us, new_name, &game.pokemon_names[index]);
                },
                c("pokedex_entry") => {
                    if (index == 0 or index - 1 >= game.species_to_national_dex.len)
                        return error.Error;
                    game.species_to_national_dex[index - 1] = try parser.parse(parselu16v);
                },
                else => return error.NoField,
            }
        },
        c("tms") => try parse.anyT(parser.str, &game.tms, converters),
        c("hms") => try parse.anyT(parser.str, &game.hms, converters),
        c("moves") => {
            const index = try parser.parse(parse.index);
            const prev = parser.str;
            const field = try parser.parse(parse.anyField);
            switch (m(field)) {
                c("name") => {
                    if (index >= game.move_names.len)
                        return error.Error;
                    try gen3.encodings.encode(.en_us, try parser.parse(parse.strv), &game.move_names[index]);
                },
                else => {
                    if (index >= game.moves.len)
                        return error.Error;
                    try parse.anyT(prev, &game.moves[index], converters);
                },
            }
        },
        c("items") => {
            const index = try parser.parse(parse.index);
            if (index >= game.items.len)
                return error.Error;
            const item = &game.items[index];

            switch (m(try parser.parse(parse.anyField))) {
                c("id") => item.id = try parser.parse(parselu16v),
                c("price") => item.price = try parser.parse(parselu16v),
                c("battle_effect") => item.battle_effect = try parser.parse(parse.u8v),
                c("battle_effect_p") => item.battle_effect_param = try parser.parse(parse.u8v),
                c("importance") => item.importance = try parser.parse(parse.u8v),
                c("type") => item.@"type" = try parser.parse(parse.u8v),
                c("battle_usage") => item.battle_usage = try parser.parse(parselu32v),
                c("secondary_id") => item.secondary_id = try parser.parse(parselu32v),
                c("name") => try gen3.encodings.encode(.en_us, try parser.parse(parse.strv), &item.name),
                c("description") => {
                    const desc_small = try item.description.toSliceZ(game.data);
                    const description = try item.description.toSlice(game.data, desc_small.len + 1);
                    try gen3.encodings.encode(.en_us, try parser.parse(parse.strv), description);
                },
                c("pocket") => switch (game.version) {
                    .ruby, .sapphire, .emerald => item.pocket = gen3.Pocket{ .rse = try parser.parse(comptime parse.enumv(gen3.RSEPocket)) },
                    .fire_red, .leaf_green => item.pocket = gen3.Pocket{ .frlg = try parser.parse(comptime parse.enumv(gen3.FRLGPocket)) },
                    else => unreachable,
                },
                else => return error.NoField,
            }
        },
        c("pokedex") => {
            const index = try parser.parse(parse.index);
            switch (game.version) {
                .emerald => {
                    if (index >= game.pokedex.emerald.len)
                        return error.Error;
                    const entry = &game.pokedex.emerald[index];

                    switch (m(try parser.parse(parse.anyField))) {
                        c("height") => entry.height = try parser.parse(parselu16v),
                        c("weight") => entry.weight = try parser.parse(parselu16v),
                        c("pokemon_scale") => entry.pokemon_scale = try parser.parse(parselu16v),
                        c("pokemon_offset") => entry.pokemon_offset = try parser.parse(parseli16v),
                        c("trainer_scale") => entry.trainer_scale = try parser.parse(parselu16v),
                        c("trainer_offset") => entry.trainer_offset = try parser.parse(parseli16v),
                        else => return error.NoField,
                    }
                },
                .ruby,
                .sapphire,
                .fire_red,
                .leaf_green,
                => {
                    if (index >= game.pokedex.rsfrlg.len)
                        return error.Error;
                    const entry = &game.pokedex.rsfrlg[index];

                    switch (m(try parser.parse(parse.anyField))) {
                        c("height") => entry.height = try parser.parse(parselu16v),
                        c("weight") => entry.weight = try parser.parse(parselu16v),
                        c("pokemon_scale") => entry.pokemon_scale = try parser.parse(parselu16v),
                        c("pokemon_offset") => entry.pokemon_offset = try parser.parse(parseli16v),
                        c("trainer_scale") => entry.trainer_scale = try parser.parse(parselu16v),
                        c("trainer_offset") => entry.trainer_offset = try parser.parse(parseli16v),
                        else => return error.NoField,
                    }
                },
                else => unreachable,
            }
        },
        c("abilities") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ability_names.len)
                return error.Error;

            switch (m(try parser.parse(parse.anyField))) {
                c("name") => try gen3.encodings.encode(.en_us, try parser.parse(parse.strv), &game.ability_names[index]),
                else => return error.Error,
            }
        },
        c("types") => {
            const index = try parser.parse(parse.index);
            if (index >= game.type_names.len)
                return error.Error;

            switch (m(try parser.parse(parse.anyField))) {
                c("name") => try gen3.encodings.encode(.en_us, try parser.parse(parse.strv), &game.type_names[index]),
                else => return error.Error,
            }
        },
        c("map") => {
            const index = try parser.parse(parse.index);
            if (index >= game.map_headers.len)
                return error.Error;

            const header = &game.map_headers[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("music") => header.music = try parser.parse(parselu16v),
                c("cave") => header.cave = try parser.parse(parse.u8v),
                c("weather") => header.weather = try parser.parse(parse.u8v),
                c("type") => header.map_type = try parser.parse(parse.u8v),
                c("escape_rope") => header.escape_rope = try parser.parse(parse.u8v),
                c("battle_scene") => header.map_battle_scene = try parser.parse(parse.u8v),
                c("allow_cycling") => header.flags.allow_cycling = try parser.parse(parse.boolv),
                c("allow_escaping") => header.flags.allow_escaping = try parser.parse(parse.boolv),
                c("allow_running") => header.flags.allow_running = try parser.parse(parse.boolv),
                c("show_map_name") => header.flags.show_map_name = try parser.parse(parse.boolv),
                else => return error.NoField,
            }
        },
        c("wild_pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.wild_pokemon_headers.len)
                return error.Error;

            const header = &game.wild_pokemon_headers[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("land") => {
                    const land = try header.land.toPtr(game.data);
                    const wilds = try land.wild_pokemons.toPtr(game.data);
                    try applyGen3Area(&parser, &land.encounter_rate, wilds);
                },
                c("surf") => {
                    const surf = try header.surf.toPtr(game.data);
                    const wilds = try surf.wild_pokemons.toPtr(game.data);
                    try applyGen3Area(&parser, &surf.encounter_rate, wilds);
                },
                c("rock_smash") => {
                    const rock = try header.rock_smash.toPtr(game.data);
                    const wilds = try rock.wild_pokemons.toPtr(game.data);
                    try applyGen3Area(&parser, &rock.encounter_rate, wilds);
                },
                c("fishing") => {
                    const fish = try header.fishing.toPtr(game.data);
                    const wilds = try fish.wild_pokemons.toPtr(game.data);
                    try applyGen3Area(&parser, &fish.encounter_rate, wilds);
                },
                else => return error.NoField,
            }
        },
        c("static_pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.static_pokemons.len)
                return error.Error;

            const static_mon = game.static_pokemons[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("species") => static_mon.species.* = try parser.parse(parselu16v),
                c("level") => static_mon.level.* = try parser.parse(parse.u8v),
                else => return error.NoField,
            }
        },
        c("given_pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.given_pokemons.len)
                return error.Error;

            const given_mon = game.given_pokemons[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("species") => given_mon.species.* = try parser.parse(parselu16v),
                c("level") => given_mon.level.* = try parser.parse(parse.u8v),
                else => return error.NoField,
            }
        },
        c("pokeball_items") => {
            const index = try parser.parse(parse.index);
            if (index >= game.pokeball_items.len)
                return error.Error;
            const given_item = game.pokeball_items[index];

            switch (m(try parser.parse(parse.anyField))) {
                c("item") => given_item.item.* = try parser.parse(parselu16v),
                c("amount") => given_item.amount.* = try parser.parse(parselu16v),
                else => return error.NoField,
            }
        },
        c("text") => {
            const index = try parser.parse(parse.index);
            if (index >= game.text.len)
                return error.Error;
            const text_ptr = game.text[index];
            const text_slice = try text_ptr.toSliceZ(game.data);

            // Slice to include the sentinel inside the slice.
            const text = text_slice[0 .. text_slice.len + 1];
            try gen3.encodings.encode(.en_us, try parser.parse(parse.strv), text);
        },
        else => return error.NoField,
    }
}

fn applyGen3Area(par: *parse.MutParser, rate: *u8, wilds: []gen3.WildPokemon) !void {
    switch (m(try par.parse(parse.anyField))) {
        c("encounter_rate") => rate.* = try par.parse(parse.u8v),
        c("pokemons") => try parse.anyT(par.str, &wilds, converters),
        else => return error.NoField,
    }
}

fn applyGen4(game: gen4.Game, str: []const u8) !void {
    var parser = parse.MutParser{ .str = str };
    const header = game.rom.header();
    switch (m(try parser.parse(parse.anyField))) {
        c("version") => {
            const value = try parser.parse(comptime parse.enumv(common.Version));
            if (value != game.info.version)
                return error.VersionDontMatch;
        },
        c("game_title") => {
            const value = try parser.parse(parse.strv);
            const null_index = mem.indexOfScalar(u8, &header.game_title, 0) //
                orelse header.game_title.len;
            if (!mem.eql(u8, value, header.game_title[0..null_index]))
                return error.GameTitleDontMatch;
        },
        c("gamecode") => {
            const value = try parser.parse(parse.strv);
            if (!mem.eql(u8, value, &header.gamecode))
                return error.GameCodeDontMatch;
        },
        c("instant_text") => {
            if (try parser.parse(parse.boolv))
                common.patch(game.owned.arm9, game.info.instant_text_patch);
        },
        c("starters") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.starters.len)
                return error.Error;
            game.ptrs.starters[index].* = try parser.parse(parselu16v);
        },
        c("trainers") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.trainers.len)
                return error.Error;

            const trainer = &game.ptrs.trainers[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("class") => trainer.class = try parser.parse(parse.u8v),
                c("battle_type") => trainer.battle_type = try parser.parse(parse.u8v),
                c("battle_type2") => trainer.battle_type2 = try parser.parse(parse.u8v),
                c("ai") => trainer.ai = try parser.parse(parselu32v),
                c("items") => try parse.anyT(parser.str, &trainer.items, converters),
                c("party_size") => trainer.party_size = try parser.parse(parse.u8v),
                c("party_type") => trainer.party_type = try parser.parse(comptime parse.enumv(gen4.PartyType)),
                c("party") => {
                    const pindex = try parser.parse(parse.index);
                    if (index >= game.owned.trainer_parties.len)
                        return error.Error;
                    if (pindex >= trainer.party_size)
                        return error.Error;

                    const member = &game.owned.trainer_parties[index][pindex];
                    switch (m(try parser.parse(parse.anyField))) {
                        c("iv") => member.base.iv = try parser.parse(parse.u8v),
                        c("gender") => member.base.gender_ability.gender = try parser.parse(parse.u4v),
                        c("ability") => member.base.gender_ability.ability = try parser.parse(parse.u4v),
                        c("level") => member.base.level = try parser.parse(parselu16v),
                        c("species") => member.base.species = try parser.parse(parselu16v),
                        c("item") => member.item = try parser.parse(parselu16v),
                        c("moves") => try parse.anyT(parser.str, &member.moves, converters),
                        else => return error.NoField,
                    }
                },
                else => return error.NoField,
            }
        },
        c("moves") => {
            const index = try parser.parse(parse.index);
            const prev = parser.str;
            const field = try parser.parse(parse.anyField);
            switch (m(field)) {
                c("description") => try applyGen4String(256, game.owned.move_descriptions, index, try parser.parse(parse.strv)),
                c("name") => try applyGen4String(16, game.owned.move_names, index, try parser.parse(parse.strv)),
                else => {
                    if (index >= game.ptrs.moves.len)
                        return error.Error;
                    try parse.anyT(prev, &game.ptrs.moves[index], converters);
                },
            }
        },
        c("items") => {
            const index = try parser.parse(parse.index);
            const prev = parser.str;
            const field = try parser.parse(parse.anyField);
            switch (m(field)) {
                c("description") => try applyGen4String(128, game.owned.item_descriptions, index, try parser.parse(parse.strv)),
                c("name") => try applyGen4String(16, game.owned.item_names, index, try parser.parse(parse.strv)),
                else => {
                    if (index >= game.ptrs.items.len)
                        return error.Error;
                    try parse.anyT(prev, &game.ptrs.items[index], converters);
                },
            }
        },
        c("pokedex") => {
            const index = try parser.parse(parse.index);
            switch (m(try parser.parse(parse.anyField))) {
                c("height") => {
                    if (index >= game.ptrs.pokedex_heights.len)
                        return error.Error;
                    game.ptrs.pokedex_heights[index] = try parser.parse(parselu32v);
                },
                c("weight") => {
                    if (index >= game.ptrs.pokedex_weights.len)
                        return error.Error;
                    game.ptrs.pokedex_weights[index] = try parser.parse(parselu32v);
                },
                else => return error.NoField,
            }
        },
        c("abilities") => {
            const index = try parser.parse(parse.index);
            switch (m(try parser.parse(parse.anyField))) {
                c("name") => try applyGen4String(16, game.owned.ability_names, index, try parser.parse(parse.strv)),
                else => return error.Error,
            }
        },
        c("types") => {
            const index = try parser.parse(parse.index);
            switch (m(try parser.parse(parse.anyField))) {
                c("name") => try applyGen4String(16, game.owned.type_names, index, try parser.parse(parse.strv)),
                else => return error.Error,
            }
        },
        c("pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.pokemons.len)
                return error.Error;
            const pokemon = &game.ptrs.pokemons[index];

            const field = try parser.parse(parse.anyField);
            switch (m(field)) {
                c("stats") => try parse.anyT(parser.str, &pokemon.stats, converters),
                c("types") => try parse.anyT(parser.str, &pokemon.types, converters),
                c("items") => try parse.anyT(parser.str, &pokemon.items, converters),
                c("abilities") => try parse.anyT(parser.str, &pokemon.abilities, converters),
                c("ev_yield") => try parse.anyT(parser.str, &pokemon.ev_yield, converters),
                c("egg_groups") => try parse.anyT(parser.str, &pokemon.egg_groups, converters),
                c("catch_rate") => pokemon.catch_rate = try parser.parse(parse.u8v),
                c("base_exp_yield") => pokemon.base_exp_yield = try parser.parse(parse.u8v),
                c("gender_ratio") => pokemon.gender_ratio = try parser.parse(parse.u8v),
                c("egg_cycles") => pokemon.egg_cycles = try parser.parse(parse.u8v),
                c("base_friendship") => pokemon.base_friendship = try parser.parse(parse.u8v),
                c("growth_rate") => pokemon.growth_rate = try parser.parse(comptime parse.enumv(common.GrowthRate)),
                c("flee_rate") => pokemon.flee_rate = try parser.parse(parse.u8v),
                c("color") => pokemon.color.color = try parser.parse(comptime parse.enumv(common.ColorKind)),
                c("flip") => pokemon.color.flip = try parser.parse(parse.boolv),
                c("name") => try applyGen4String(16, game.owned.pokemon_names, index, try parser.parse(parse.strv)),
                c("tms"), c("hms") => {
                    const is_tms = c("tms") == m(field);
                    const tindex = try parser.parse(parse.index);
                    const value = try parser.parse(parse.boolv);
                    const len = if (is_tms) game.ptrs.tms.len else game.ptrs.hms.len;
                    if (tindex >= len)
                        return error.Error;

                    const rindex = tindex + game.ptrs.tms.len * @boolToInt(!is_tms);
                    const learnset = &pokemon.machine_learnset;
                    learnset.* = lu128.init(bit.setTo(u128, learnset.value(), @intCast(u7, rindex), value));
                },
                c("moves") => {
                    const bytes = game.ptrs.level_up_moves.fileData(.{ .i = @intCast(u32, index) });
                    const rem = bytes.len % @sizeOf(gen4.LevelUpMove);
                    const lum = mem.bytesAsSlice(gen4.LevelUpMove, bytes[0 .. bytes.len - rem]);
                    try parse.anyT(parser.str, &lum, converters);
                },
                c("evos") => {
                    if (game.ptrs.evolutions.len <= index)
                        return error.Error;
                    try parse.anyT(parser.str, &game.ptrs.evolutions[index].items, converters);
                },
                c("pokedex_entry") => {
                    if (index == 0 or index - 1 >= game.ptrs.species_to_national_dex.len)
                        return error.Error;
                    game.ptrs.species_to_national_dex[index - 1] = try parser.parse(parselu16v);
                },
                else => return error.NoField,
            }
        },
        c("tms") => try parse.anyT(parser.str, &game.ptrs.tms, converters),
        c("hms") => try parse.anyT(parser.str, &game.ptrs.hms, converters),
        c("wild_pokemons") => {
            const wild_pokemons = game.ptrs.wild_pokemons;
            const index = try parser.parse(parse.index);

            switch (game.info.version) {
                .diamond,
                .pearl,
                .platinum,
                => {
                    const wilds = &wild_pokemons.dppt[index];
                    switch (m(try parser.parse(parse.anyField))) {
                        c("grass") => switch (m(try parser.parse(parse.anyField))) {
                            c("encounter_rate") => wilds.grass_rate = try parser.parse(parselu32v),
                            c("pokemons") => {
                                const i = try parser.parse(parse.index);
                                if (i >= wilds.grass.len)
                                    return error.IndexOutOfBound;
                                switch (m(try parser.parse(parse.anyField))) {
                                    c("min_level") => wilds.grass[i].level = try parser.parse(parse.u8v),
                                    c("max_level") => wilds.grass[i].level = try parser.parse(parse.u8v),
                                    c("species") => wilds.grass[i].species = try parser.parse(parselu16v),
                                    else => return error.NoField,
                                }
                            },
                            else => return error.NoField,
                        },
                        c("swarm_replace") => try applyDpptReplacement(&parser, &wilds.swarm_replace),
                        c("day_replace") => try applyDpptReplacement(&parser, &wilds.day_replace),
                        c("night_replace") => try applyDpptReplacement(&parser, &wilds.night_replace),
                        c("radar_replace") => try applyDpptReplacement(&parser, &wilds.radar_replace),
                        c("unknown_replace") => try applyDpptReplacement(&parser, &wilds.unknown_replace),
                        c("gba_replace") => try applyDpptReplacement(&parser, &wilds.gba_replace),
                        c("surf") => try applyDpptSea(&parser, &wilds.surf),
                        c("sea_unknown") => try applyDpptSea(&parser, &wilds.sea_unknown),
                        c("old_rod") => try applyDpptSea(&parser, &wilds.old_rod),
                        c("good_rod") => try applyDpptSea(&parser, &wilds.good_rod),
                        c("super_rod") => try applyDpptSea(&parser, &wilds.super_rod),
                        else => return error.NoField,
                    }
                },

                .heart_gold,
                .soul_silver,
                => {
                    const wilds = &wild_pokemons.hgss[index];
                    switch (m(try parser.parse(parse.anyField))) {
                        c("grass_morning") => try applyHgssGrass(&parser, wilds, &wilds.grass_morning),
                        c("grass_day") => try applyHgssGrass(&parser, wilds, &wilds.grass_day),
                        c("grass_night") => try applyHgssGrass(&parser, wilds, &wilds.grass_night),
                        c("surf") => try applyHgssSea(&parser, &wilds.sea_rates[0], &wilds.surf),
                        c("sea_unknown") => try applyHgssSea(&parser, &wilds.sea_rates[1], &wilds.sea_unknown),
                        c("old_rod") => try applyHgssSea(&parser, &wilds.sea_rates[2], &wilds.old_rod),
                        c("good_rod") => try applyHgssSea(&parser, &wilds.sea_rates[3], &wilds.good_rod),
                        c("super_rod") => try applyHgssSea(&parser, &wilds.sea_rates[4], &wilds.super_rod),
                        else => return error.NoField,
                    }
                },
                else => unreachable,
            }
        },
        c("static_pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.static_pokemons.len)
                return error.Error;

            const static_mon = game.ptrs.static_pokemons[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("species") => static_mon.species.* = try parser.parse(parselu16v),
                c("level") => static_mon.level.* = try parser.parse(parselu16v),
                else => return error.NoField,
            }
        },
        c("given_pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.given_pokemons.len)
                return error.Error;

            const given_mon = game.ptrs.given_pokemons[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("species") => given_mon.species.* = try parser.parse(parselu16v),
                c("level") => given_mon.level.* = try parser.parse(parselu16v),
                else => return error.NoField,
            }
        },
        c("pokeball_items") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.pokeball_items.len)
                return error.Error;
            const given_item = game.ptrs.pokeball_items[index];

            switch (m(try parser.parse(parse.anyField))) {
                c("item") => given_item.item.* = try parser.parse(parselu16v),
                c("amount") => given_item.amount.* = try parser.parse(parselu16v),
                else => return error.NoField,
            }
        },
        else => return error.NoField,
    }
}

fn applyHgssGrass(par: *parse.MutParser, wilds: *gen4.HgssWildPokemons, grass: *[12]lu16) !void {
    switch (m(try par.parse(parse.anyField))) {
        c("encounter_rate") => wilds.grass_rate = try par.parse(parse.u8v),
        c("pokemons") => {
            const index = try par.parse(parse.index);
            if (index >= grass.len)
                return error.Error;
            switch (m(try par.parse(parse.anyField))) {
                c("min_level") => wilds.grass_levels[index] = try par.parse(parse.u8v),
                c("max_level") => wilds.grass_levels[index] = try par.parse(parse.u8v),
                c("species") => grass[index] = try par.parse(parselu16v),
                else => return error.NoField,
            }
        },
        else => return error.NoField,
    }
}

fn applyHgssSea(par: *parse.MutParser, rate: *u8, sea: []gen4.HgssWildPokemons.Sea) !void {
    switch (m(try par.parse(parse.anyField))) {
        c("encounter_rate") => rate.* = try par.parse(parse.u8v),
        c("pokemons") => try parse.anyT(par.str, &sea, converters),
        else => return error.NoField,
    }
}

fn applyDpptReplacement(par: *parse.MutParser, area: []gen4.DpptWildPokemons.Replacement) !void {
    try par.parse(comptime parse.field("pokemons"));
    try parse.anyT(par.str, &area, converters);
}

fn applyDpptSea(par: *parse.MutParser, sea: *gen4.DpptWildPokemons.Sea) !void {
    switch (m(try par.parse(parse.anyField))) {
        c("encounter_rate") => sea.rate = try par.parse(parselu32v),
        c("pokemons") => try parse.anyT(par.str, &sea.mons, converters),
        else => return error.NoField,
    }
}

fn applyGen4String(comptime l: usize, strs: []gen4.String(l), index: usize, value: []const u8) !void {
    if (strs.len <= index)
        return error.Error;

    var buf = [_]u8{0} ** l;
    var fba = io.fixedBufferStream(&buf);
    try escape.writeUnEscaped(fba.writer(), value, escape.zig_escapes);
    strs[index].buf = buf;
}

fn applyGen5(game: gen5.Game, str: []const u8) !void {
    var parser = parse.MutParser{ .str = str };
    const header = game.rom.header();

    switch (m(try parser.parse(parse.anyField))) {
        c("version") => {
            const value = try parser.parse(comptime parse.enumv(common.Version));
            if (value != game.info.version)
                return error.VersionDontMatch;
        },
        c("game_title") => {
            const value = try parser.parse(parse.strv);
            const null_index = mem.indexOfScalar(u8, &header.game_title, 0) //
                orelse header.game_title.len;
            if (!mem.eql(u8, value, header.game_title[0..null_index]))
                return error.GameTitleDontMatch;
        },
        c("gamecode") => {
            const value = try parser.parse(parse.strv);
            if (!mem.eql(u8, value, &header.gamecode))
                return error.GameCodeDontMatch;
        },
        c("instant_text") => {
            if (try parser.parse(parse.boolv))
                common.patch(game.owned.arm9, game.info.instant_text_patch);
        },
        c("starters") => {
            const index = try parser.parse(parse.index);
            const value = try parser.parse(parselu16v);
            if (index >= game.ptrs.starters.len)
                return error.Error;
            for (game.ptrs.starters[index]) |starter|
                starter.* = value;
        },
        c("trainers") => {
            const index = try parser.parse(parse.index);
            if (index == 0 or index - 1 >= game.ptrs.trainers.len)
                return error.Error;

            const trainer = &game.ptrs.trainers[index - 1];
            switch (m(try parser.parse(parse.anyField))) {
                c("class") => trainer.class = try parser.parse(parse.u8v),
                c("battle_type") => trainer.battle_type = try parser.parse(parse.u8v),
                c("ai") => trainer.ai = try parser.parse(parselu32v),
                c("is_healer") => trainer.healer = try parser.parse(parse.boolv),
                c("cash") => trainer.cash = try parser.parse(parse.u8v),
                c("post_battle_item") => trainer.post_battle_item = try parser.parse(parselu16v),
                c("items") => try parse.anyT(parser.str, &trainer.items, converters),
                c("name") => try applyGen5String(game.owned.strings.trainer_names, index, try parser.parse(parse.strv)),
                c("party_size") => trainer.party_size = try parser.parse(parse.u8v),
                c("party_type") => trainer.party_type = try parser.parse(comptime parse.enumv(gen5.PartyType)),
                c("party") => {
                    const pindex = try parser.parse(parse.index);
                    if (index >= game.owned.trainer_parties.len)
                        return error.Error;
                    if (pindex >= trainer.party_size)
                        return error.Error;

                    const member = &game.owned.trainer_parties[index][pindex];
                    switch (m(try parser.parse(parse.anyField))) {
                        c("iv") => member.base.iv = try parser.parse(parse.u8v),
                        c("gender") => member.base.gender_ability.gender = try parser.parse(parse.u4v),
                        c("ability") => member.base.gender_ability.ability = try parser.parse(parse.u4v),
                        c("level") => member.base.level = try parser.parse(parse.u8v),
                        c("species") => member.base.species = try parser.parse(parselu16v),
                        c("form") => member.base.form = try parser.parse(parselu16v),
                        c("item") => member.item = try parser.parse(parselu16v),
                        c("moves") => try parse.anyT(parser.str, &member.moves, converters),
                        else => return error.NoField,
                    }
                },
                else => return error.NoField,
            }
        },
        c("pokemons") => {
            const index = @intCast(u32, try parser.parse(parse.index));
            if (index >= game.ptrs.pokemons.fat.len)
                return error.Error;

            const pokemon = try game.ptrs.pokemons.fileAs(.{ .i = index }, gen5.BasePokemon);
            const field = try parser.parse(parse.anyField);
            switch (m(field)) {
                c("stats") => try parse.anyT(parser.str, &pokemon.stats, converters),
                c("types") => try parse.anyT(parser.str, &pokemon.types, converters),
                c("items") => try parse.anyT(parser.str, &pokemon.items, converters),
                c("abilities") => try parse.anyT(parser.str, &pokemon.abilities, converters),
                c("egg_groups") => try parse.anyT(parser.str, &pokemon.egg_groups, converters),
                c("catch_rate") => pokemon.catch_rate = try parser.parse(parse.u8v),
                c("gender_ratio") => pokemon.gender_ratio = try parser.parse(parse.u8v),
                c("egg_cycles") => pokemon.egg_cycles = try parser.parse(parse.u8v),
                c("base_friendship") => pokemon.base_friendship = try parser.parse(parse.u8v),
                c("growth_rate") => pokemon.growth_rate = try parser.parse(comptime parse.enumv(common.GrowthRate)),
                c("color") => pokemon.color.color = try parser.parse(comptime parse.enumv(common.ColorKind)),
                c("flip") => pokemon.color.flip = try parser.parse(parse.boolv),
                c("height") => pokemon.height = try parser.parse(parselu16v),
                c("weight") => pokemon.weight = try parser.parse(parselu16v),
                c("name") => try applyGen5String(game.owned.strings.pokemon_names, index, try parser.parse(parse.strv)),
                c("tms"), c("hms") => {
                    const is_tms = c("tms") == m(field);
                    const tindex = try parser.parse(parse.index);
                    const value = try parser.parse(parse.boolv);
                    const len = if (is_tms) game.ptrs.tms1.len + game.ptrs.tms2.len else game.ptrs.hms.len;
                    if (tindex >= len)
                        return error.Error;

                    const rindex = if (is_tms) tindex else tindex + game.ptrs.tms1.len + game.ptrs.tms2.len;
                    const learnset = &pokemon.machine_learnset;
                    learnset.* = lu128.init(bit.setTo(u128, learnset.value(), @intCast(u7, rindex), value));
                },
                c("moves") => {
                    const bytes = game.ptrs.level_up_moves.fileData(.{ .i = @intCast(u32, index) });
                    const rem = bytes.len % @sizeOf(gen5.LevelUpMove);
                    const lum = mem.bytesAsSlice(gen5.LevelUpMove, bytes[0 .. bytes.len - rem]);
                    try parse.anyT(parser.str, &lum, converters);
                },
                c("evos") => {
                    if (game.ptrs.evolutions.len <= index)
                        return error.Error;
                    try parse.anyT(parser.str, &game.ptrs.evolutions[index].items, converters);
                },
                c("pokedex_entry") => {
                    const entry = try parser.parse(parse.u16v);
                    if (index != entry)
                        return error.TryingToChangeReadOnlyField;
                },
                else => return error.NoField,
            }
        },
        c("tms") => {
            const index = try parser.parse(parse.index);
            const value = try parser.parse(parselu16v);
            if (index >= game.ptrs.tms1.len + game.ptrs.tms2.len)
                return error.Error;
            if (index < game.ptrs.tms1.len) {
                game.ptrs.tms1[index] = value;
            } else {
                game.ptrs.tms2[index - game.ptrs.tms1.len] = value;
            }
        },
        c("hms") => try parse.anyT(parser.str, &game.ptrs.hms, converters),
        c("items") => {
            const index = try parser.parse(parse.index);
            const prev = parser.str;
            const field = try parser.parse(parse.anyField);
            switch (m(field)) {
                c("description") => try applyGen5String(game.owned.strings.item_descriptions, index, try parser.parse(parse.strv)),
                c("name") => {
                    const item_names = game.owned.strings.item_names;
                    if (index >= item_names.keys.len)
                        return error.Error;
                    const new_name = try parser.parse(parse.strv);
                    const old_name = item_names.getSpan(index);

                    // Here, we also applies the item name to the item_names_on_the_ground
                    // table. The way we do this is to search for the item name in the
                    // ground string, and if it exists, we replace it and apply this new
                    // string
                    applyGen5StringReplace(
                        game.owned.strings.item_names_on_the_ground,
                        index,
                        old_name,
                        new_name,
                    ) catch {};
                    try applyGen5String(item_names, index, new_name);
                },
                c("price") => {
                    if (index >= game.ptrs.items.len)
                        return error.Error;
                    const item = &game.ptrs.items[index];
                    const parsed_price = try parser.parse(parse.u32v);
                    const new_price = try math.cast(u16, parsed_price / 10);
                    item.price = lu16.init(new_price);
                },
                else => {
                    if (index >= game.ptrs.items.len)
                        return error.Error;
                    try parse.anyT(prev, &game.ptrs.items[index], converters);
                },
            }
        },
        c("pokedex") => {
            const index = try parser.parse(parse.index);
            switch (m(try parser.parse(parse.anyField))) {
                c("category") => try applyGen5String(game.owned.strings.pokedex_category_names, index, try parser.parse(parse.strv)),
                else => return error.Error,
            }
        },
        c("moves") => {
            const prev = parser.str;
            const index = try parser.parse(parse.index);
            switch (m(try parser.parse(parse.anyField))) {
                c("description") => try applyGen5String(game.owned.strings.move_descriptions, index, try parser.parse(parse.strv)),
                c("name") => try applyGen5String(game.owned.strings.move_names, index, try parser.parse(parse.strv)),
                else => try parse.anyT(prev, &game.ptrs.moves, converters),
            }
        },
        c("abilities") => {
            const index = try parser.parse(parse.index);
            switch (m(try parser.parse(parse.anyField))) {
                c("name") => try applyGen5String(game.owned.strings.ability_names, index, try parser.parse(parse.strv)),
                else => return error.Error,
            }
        },
        c("types") => {
            const index = try parser.parse(parse.index);
            switch (m(try parser.parse(parse.anyField))) {
                c("name") => try applyGen5String(game.owned.strings.type_names, index, try parser.parse(parse.strv)),
                else => return error.Error,
            }
        },
        c("map") => try parse.anyT(parser.str, &game.ptrs.map_headers, converters),
        c("wild_pokemons") => {
            const H = struct {
                fn applyArea(par: *parse.MutParser, comptime name: []const u8, index: usize, wilds: *gen5.WildPokemons) !void {
                    switch (m(try par.parse(parse.anyField))) {
                        c("encounter_rate") => wilds.rates[index] = try par.parse(parse.u8v),
                        c("pokemons") => {
                            const windex = try par.parse(parse.index);
                            const area = &@field(wilds, name);
                            if (windex >= area.len)
                                return error.Error;
                            const wild = &area[windex];

                            switch (m(try par.parse(parse.anyField))) {
                                c("min_level") => wild.min_level = try par.parse(parse.u8v),
                                c("max_level") => wild.max_level = try par.parse(parse.u8v),
                                c("species") => wild.species.setSpecies(try par.parse(parse.u10v)),
                                c("form") => wild.species.setForm(try par.parse(parse.u6v)),
                                else => return error.NoField,
                            }
                        },
                        else => return error.Error,
                    }
                }
            };

            const index = @intCast(u32, try parser.parse(parse.index));

            if (index >= game.ptrs.wild_pokemons.fat.len)
                return error.Error;

            const wilds = try game.ptrs.wild_pokemons.fileAs(.{ .i = index }, gen5.WildPokemons);
            switch (m(try parser.parse(parse.anyField))) {
                c("grass") => try H.applyArea(&parser, "grass", 0, wilds),
                c("dark_grass") => try H.applyArea(&parser, "dark_grass", 1, wilds),
                c("rustling_grass") => try H.applyArea(&parser, "rustling_grass", 2, wilds),
                c("surf") => try H.applyArea(&parser, "surf", 3, wilds),
                c("ripple_surf") => try H.applyArea(&parser, "ripple_surf", 4, wilds),
                c("fishing") => try H.applyArea(&parser, "fishing", 5, wilds),
                c("ripple_fishing") => try H.applyArea(&parser, "ripple_fishing", 6, wilds),
                else => return error.NoField,
            }
        },
        c("static_pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.static_pokemons.len)
                return error.Error;

            const static_mon = game.ptrs.static_pokemons[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("species") => static_mon.species.* = try parser.parse(parselu16v),
                c("level") => static_mon.level.* = try parser.parse(parselu16v),
                else => return error.NoField,
            }
        },
        c("given_pokemons") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.given_pokemons.len)
                return error.Error;

            const given_mon = game.ptrs.given_pokemons[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("species") => given_mon.species.* = try parser.parse(parselu16v),
                c("level") => given_mon.level.* = try parser.parse(parselu16v),
                else => return error.NoField,
            }
        },
        c("pokeball_items") => {
            const index = try parser.parse(parse.index);
            if (index >= game.ptrs.pokeball_items.len)
                return error.Error;
            const given_item = game.ptrs.pokeball_items[index];

            switch (m(try parser.parse(parse.anyField))) {
                c("item") => given_item.item.* = try parser.parse(parselu16v),
                c("amount") => given_item.amount.* = try parser.parse(parselu16v),
                else => return error.NoField,
            }
        },
        c("hidden_hollows") => if (game.ptrs.hidden_hollows) |hollows| {
            const index = try parser.parse(parse.index);
            if (index >= hollows.len)
                return error.Error;

            const hollow = &hollows[index];
            switch (m(try parser.parse(parse.anyField))) {
                c("versions") => {
                    const vindex = try parser.parse(parse.index);
                    if (vindex >= hollow.pokemons.len)
                        return error.Error;

                    const version = &hollow.pokemons[vindex];
                    try parser.parse(comptime parse.field("groups"));
                    const gindex = try parser.parse(parse.index);
                    if (gindex >= version.len)
                        return error.Error;

                    const group = &version[gindex];
                    try parser.parse(comptime parse.field("pokemons"));
                    const pindex = try parser.parse(parse.index);
                    if (pindex >= group.species.len)
                        return error.Error;

                    switch (m(try parser.parse(parse.anyField))) {
                        c("species") => try parse.anyT(parser.str, &group.species[pindex], converters),
                        c("gender") => try parse.anyT(parser.str, &group.genders[pindex], converters),
                        c("form") => try parse.anyT(parser.str, &group.forms[pindex], converters),
                        else => return error.NoField,
                    }
                },
                c("items") => try parse.anyT(parser.str, &hollow.items, converters),
                else => return error.NoField,
            }
        } else {
            return error.NoField;
        },
        else => return error.NoField,
    }
}

fn applyGen5StringReplace(
    strs: gen5.StringTable,
    index: usize,
    search_for: []const u8,
    replace_with: []const u8,
) !void {
    if (strs.keys.len <= index)
        return error.Error;

    const str = strs.getSpan(index);
    const i = mem.indexOf(u8, str, search_for) orelse return;
    const before = str[0..i];
    const after = str[i + search_for.len ..];

    var buf: [1024]u8 = undefined;
    const writer = io.fixedBufferStream(&buf).writer();
    try writer.writeAll(before);
    try escape.writeUnEscaped(writer, replace_with, escape.zig_escapes);
    try writer.writeAll(after);
    _ = writer.write("\x00") catch undefined;

    const written = writer.context.getWritten();
    const copy_into = strs.get(index);
    if (copy_into.len < written.len)
        return error.Error;

    mem.copy(u8, copy_into, written);

    // Null terminate, if we didn't fill the buffer
    if (written.len < copy_into.len)
        buf[written.len] = 0;
}

fn applyGen5String(strs: gen5.StringTable, index: usize, value: []const u8) !void {
    if (strs.keys.len <= index)
        return error.Error;

    const buf = strs.get(index);
    const writer = io.fixedBufferStream(buf).writer();
    try escape.writeUnEscaped(writer, value, escape.zig_escapes);

    // Null terminate, if we didn't fill the buffer
    if (writer.context.pos < buf.len)
        buf[writer.context.pos] = 0;
}
