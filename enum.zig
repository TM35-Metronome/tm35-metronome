pub const Kind = packed enum(u8) {
    nop     = 0x00,
    nop1    = 0x01,
    end     = 0x02,
    @"return"   = 0x03,
    call    = 0x04,
    goto    = 0x05,
    goto_if     = 0x06,
    call_if     = 0x07,
    gotostd     = 0x08,
    callstd     = 0x09,
    gotostd_if  = 0x0a,
    callstd_if  = 0x0b,
    gotoram     = 0x0c,
    killscript  = 0x0d,
    setmysteryeventstatus   = 0x0e,
    loadword    = 0x0f,
    loadbyte    = 0x10,
    writebytetoaddr     = 0x11,
    loadbytefromaddr    = 0x12,
    setptrbyte  = 0x13,
    copylocal   = 0x14,
    copybyte    = 0x15,
    setvar  = 0x16,
    addvar  = 0x17,
    subvar  = 0x18,
    copyvar     = 0x19,
    setorcopyvar    = 0x1a,
    compare_local_to_local  = 0x1b,
    compare_local_to_value  = 0x1c,
    compare_local_to_addr   = 0x1d,
    compare_addr_to_local   = 0x1e,
    compare_addr_to_value   = 0x1f,
    compare_addr_to_addr    = 0x20,
    compare_var_to_value    = 0x21,
    compare_var_to_var  = 0x22,
    callnative  = 0x23,
    gotonative  = 0x24,
    special     = 0x25,
    specialvar  = 0x26,
    specialvar_     = 0x26,
    waitstate   = 0x27,
    delay   = 0x28,
    setflag     = 0x29,
    clearflag   = 0x2a,
    checkflag   = 0x2b,
    initclock   = 0x2c,
    dodailyevents   = 0x2d,
    gettime     = 0x2e,
    playse  = 0x2f,
    waitse  = 0x30,
    playfanfare     = 0x31,
    waitfanfare     = 0x32,
    playbgm     = 0x33,
    savebgm     = 0x34,
    fadedefaultbgm  = 0x35,
    fadenewbgm  = 0x36,
    fadeoutbgm  = 0x37,
    fadeinbgm   = 0x38,
    warp    = 0x39,
    warpsilent  = 0x3a,
    warpdoor    = 0x3b,
    warphole    = 0x3c,
    warpteleport    = 0x3d,
    setwarp     = 0x3e,
    setdynamicwarp  = 0x3f,
    setdivewarp     = 0x40,
    setholewarp     = 0x41,
    getplayerxy     = 0x42,
    getpartysize    = 0x43,
    giveitem    = 0x44,
    takeitem    = 0x45,
    checkitemspace  = 0x46,
    checkitem   = 0x47,
    checkitemtype   = 0x48,
    givepcitem  = 0x49,
    checkpcitem     = 0x4a,
    givedecoration  = 0x4b,
    takedecoration  = 0x4c,
    checkdecor  = 0x4d,
    checkdecorspace     = 0x4e,
    setobjectxy     = 0x57,
    showobjectat    = 0x58,
    hideobjectat    = 0x59,
    faceplayer  = 0x5a,
    turnobject  = 0x5b,
    trainerbattle   = 0x5c,
    trainerbattlebegin  = 0x5d,
    gotopostbattlescript    = 0x5e,
    gotobeatenscript    = 0x5f,
    checktrainerflag    = 0x60,
    settrainerflag  = 0x61,
    cleartrainerflag    = 0x62,
    setobjectxyperm     = 0x63,
    moveobjectoffscreen     = 0x64,
    setobjectmovementtype   = 0x65,
    waitmessage     = 0x66,
    message     = 0x67,
    closemessage    = 0x68,
    lockall     = 0x69,
    lock    = 0x6a,
    releaseall  = 0x6b,
    release     = 0x6c,
    waitbuttonpress     = 0x6d,
    yesnobox    = 0x6e,
    multichoice     = 0x6f,
    multichoicedefault  = 0x70,
    multichoicegrid     = 0x71,
    drawbox     = 0x72,
    erasebox    = 0x73,
    drawboxtext     = 0x74,
    drawmonpic  = 0x75,
    erasemonpic     = 0x76,
    drawcontestwinner   = 0x77,
    braillemessage  = 0x78,
    givemon     = 0x79,
    giveegg     = 0x7a,
    setmonmove  = 0x7b,
    checkpartymove  = 0x7c,
    bufferspeciesname   = 0x7d,
    bufferleadmonspeciesname    = 0x7e,
    bufferpartymonnick  = 0x7f,
    bufferitemname  = 0x80,
    bufferdecorationname    = 0x81,
    buffermovename  = 0x82,
    buffernumberstring  = 0x83,
    bufferstdstring     = 0x84,
    bufferstring    = 0x85,
    pokemart    = 0x86,
    pokemartdecoration  = 0x87,
    pokemartdecoration2     = 0x88,
    playslotmachine     = 0x89,
    setberrytree    = 0x8a,
    choosecontestmon    = 0x8b,
    startcontest    = 0x8c,
    showcontestresults  = 0x8d,
    contestlinktransfer     = 0x8e,
    random  = 0x8f,
    givemoney   = 0x90,
    takemoney   = 0x91,
    checkmoney  = 0x92,
    showmoneybox    = 0x93,
    hidemoneybox    = 0x94,
    updatemoneybox  = 0x95,
    getpricereduction   = 0x96,
    fadescreen  = 0x97,
    fadescreenspeed     = 0x98,
    setflashradius  = 0x99,
    animateflash    = 0x9a,
    messageautoscroll   = 0x9b,
    dofieldeffect   = 0x9c,
    setfieldeffectargument  = 0x9d,
    waitfieldeffect     = 0x9e,
    setrespawn  = 0x9f,
    checkplayergender   = 0xa0,
    playmoncry  = 0xa1,
    setmetatile     = 0xa2,
    resetweather    = 0xa3,
    setweather  = 0xa4,
    doweather   = 0xa5,
    setstepcallback     = 0xa6,
    setmaplayoutindex   = 0xa7,
    setobjectpriority   = 0xa8,
    resetobjectpriority     = 0xa9,
    createvobject   = 0xaa,
    turnvobject     = 0xab,
    opendoor    = 0xac,
    closedoor   = 0xad,
    waitdooranim    = 0xae,
    setdooropen     = 0xaf,
    setdoorclosed   = 0xb0,
    addelevmenuitem     = 0xb1,
    showelevmenu    = 0xb2,
    checkcoins  = 0xb3,
    givecoins   = 0xb4,
    takecoins   = 0xb5,
    setwildbattle   = 0xb6,
    dowildbattle    = 0xb7,
    setvaddress     = 0xb8,
    vgoto   = 0xb9,
    vcall   = 0xba,
    vgoto_if    = 0xbb,
    vcall_if    = 0xbc,
    vmessage    = 0xbd,
    vloadptr    = 0xbe,
    vbufferstring   = 0xbf,
    showcoinsbox    = 0xc0,
    hidecoinsbox    = 0xc1,
    updatecoinsbox  = 0xc2,
    incrementgamestat   = 0xc3,
    setescapewarp   = 0xc4,
    waitmoncry  = 0xc5,
    bufferboxname   = 0xc6,
    textcolor   = 0xc7,
    loadhelp    = 0xc8,
    unloadhelp  = 0xc9,
    signmsg     = 0xca,
    normalmsg   = 0xcb,
    comparehiddenvar    = 0xcc,
    setmonobedient  = 0xcd,
    checkmonobedience   = 0xce,
    execram     = 0xcf,
    setworldmapflag     = 0xd0,
    warpteleport2   = 0xd1,
    setmonmetlocation   = 0xd2,
    mossdeepgym1    = 0xd3,
    mossdeepgym2    = 0xd4,
    mossdeepgym3    = 0xd5,
    mossdeepgym4    = 0xd6,
    warp7   = 0xd7,
    cmdD8   = 0xd8,
    cmdD9   = 0xd9,
    hidebox2    = 0xda,
    message3    = 0xdb,
    fadescreenswapbuffers   = 0xdc,
    buffertrainerclassname  = 0xdd,
    buffertrainername   = 0xde,
    pokenavcall     = 0xdf,
    warp8   = 0xe0,
    buffercontesttypestring     = 0xe1,
    bufferitemnameplural    = 0xe2,
};
