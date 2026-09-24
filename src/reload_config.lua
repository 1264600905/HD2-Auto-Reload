-- Static, build-time configuration. Edit this file and rebuild the package.
-- false keeps ordinary empty reloads; true enables the limits below.
local ENABLE_TACTICAL_RELOAD = false -- 启用战术换弹

-- Keys are exact resource IDs for player-held weapons in build 25327279.
-- limit counts the selected magazine only unless basis='total' is specified.
-- immediate skips the firing-click wait for fast weapons.
-- continuous is for weapons that load individual rounds. Do not use it for AC-8.
local tactical_rules = {
    -- AR family (JAR-5, sentries, drones and vehicle weapons excluded).
    ['84354339522c932d'] = {name='AR-2', path='weapon_magazine', limit=3, immediate=true},
    ['968211c0033dce64'] = {name='AR-23', path='weapon_magazine', limit=3, immediate=true},
    ['a7ee1ebf58fcdf1f'] = {name='AR-23A', path='weapon_magazine', limit=3, immediate=true},
    ['cf5f176e0e322be1'] = {name='AR-23C', path='weapon_magazine', limit=3, immediate=true},
    ['43cb1033961a2276'] = {name='AR-23P', path='weapon_magazine', limit=3, immediate=true},
    ['bc29613666df696b'] = {name='AR-32', path='weapon_magazine', limit=3, immediate=true},
    ['708ea298c82093d0'] = {name='AR-59', path='weapon_magazine', limit=3, immediate=true},
    ['ce063aa33d95a812'] = {name='AR-61', path='weapon_magazine', limit=3, immediate=true},
    ['a955c4ea6f6d4203'] = {name='AR/GL-21', path='weapon_magazine', limit=3, immediate=true},
    ['5fecab819f96a3e8'] = {name='BR-14', path='weapon_magazine', limit=3, immediate=true},
    ['0f83639ab8c86165'] = {name='R-2', path='weapon_magazine', limit=0},
    ['e5796355a8fd67e0'] = {name='R-4', path='weapon_magazine', limit=0},
    ['f0338468dcdb6a6c'] = {name='R-72', path='weapon_magazine', limit=0},
    ['03e67a19b07c6523'] = {name='R-63', path='weapon_magazine', limit=0},
    ['4c786785c79d44e7'] = {name='R-63CS', path='weapon_magazine', limit=0},
    ['4ba41b6f9f405cc2'] = {name='StA-11', path='weapon_magazine', limit=3, immediate=true},
    ['be70ee0d8d44028e'] = {name='M7S', path='weapon_magazine', limit=3, immediate=true},
    ['186ea95de7306b1a'] = {name='SMG-203', path='weapon_magazine', limit=3, immediate=true},
    ['94bd931b5fb4ee95'] = {name='SMG-32', path='weapon_magazine', limit=3, immediate=true},
    ['4e4a613eb9bf5c24'] = {name='SMG-37', path='weapon_magazine', limit=3, immediate=true},
    ['0807aea5217e4767'] = {name='SMG-72', path='weapon_magazine', limit=3, immediate=true},
    ['8a307bd1811a5fe9'] = {name='SMG/FLAM-34', path='weapon_magazine', limit=3, immediate=true},
    ['46183b50961d1328'] = {name='SG-225', path='weapon_magazine', limit=0},
    ['c12a34f375bd5a87'] = {name='SG-225IE', path='weapon_magazine', limit=0},
    ['5ebaea70c0d060b9'] = {name='SG-225SP', path='weapon_magazine', limit=0},
    ['f49227a0630a3f7f'] = {name='CB-9', path='weapon_magazine', limit=0},
    ['cf8934ff6567a42d'] = {name='P-92', path='weapon_magazine', limit=0},
    ['05e4e5c2db6e44a2'] = {name='P-2', path='weapon_magazine', limit=3, immediate=true},
    ['3575aabc5f1f9326'] = {name='P-19', path='weapon_magazine', limit=3, immediate=true},
    ['1a437158e1b8d2a1'] = {name='P-113', path='weapon_magazine', limit=0},
    ['4d58c77087b774c5'] = {name='M6C/SOCOM', path='weapon_magazine', limit=3, immediate=true},
    ['dbb6c961c59fadc1'] = {name='P-40-K', path='weapon_magazine', limit=0},

    -- WeaponRounds: use the selected magazine count unless the old total rule is explicit.
    ['7b75e5132ffd4ca6'] = {name='R-2124', path='weapon_rounds', limit=2, continuous=true},
    ['e6d932be83729076'] = {name='R-6', path='weapon_rounds', limit=3, continuous=true},
    ['41eac4a03987faa0'] = {name='SG-8', path='weapon_rounds', limit=8, continuous=true},
    ['4f749e2ee26f532d'] = {name='SG-8S', path='weapon_rounds', limit=8, continuous=true},
    ['05d8d8c073b9d502'] = {name='SG-8P', path='weapon_magazine', limit=8},
    ['4e310b1fe4c52b52'] = {name='SG-20', path='weapon_rounds', limit=8, continuous=true},
    ['d323de60855898ac'] = {name='SG-451', path='weapon_rounds', limit=8, continuous=true},
    ['dcd1c835407ef7ba'] = {name='SG-97', path='weapon_rounds', limit=4, basis='total', continuous=true},
    ['90ddc374f4e3d756'] = {name='M90A', path='weapon_rounds', limit=3, continuous=true},
    ['006e44327bb953fe'] = {name='GL-15', path='weapon_rounds', limit=2, basis='total', continuous=true},
    ['c780bcd79547da0f'] = {name='P-69', path='weapon_rounds', limit=6, continuous=true},
    ['b6aff2195568767f'] = {name='R-36', path='weapon_magazine', limit=0},

    -- Support weapons. MK variants below are handheld, not sentries or vehicles.
    ['89c5493e08ca4207'] = {name='APW-1', path='weapon_magazine', limit=0},
    ['a6a735accb4a327f'] = {name='M-105', path='weapon_magazine', limit=10, immediate=true},
    ['b43235dbd493750c'] = {name='M-105 MK3', path='weapon_magazine', limit=10, immediate=true},
    ['a8cffb316f0b5c5f'] = {name='AC-8', path='weapon_rounds', limit=0},
    ['02eecd0b1fa49630'] = {name='GL-21', path='weapon_magazine', limit=0},
    ['1d5943301a29c940'] = {name='GL-21 MK2', path='weapon_magazine', limit=0},
}

-- These weapons only request R after a verified empty state and a new attack press.
-- MG-43 uses the Magazine reader experimentally after the user's request.
local attack_only_resources = {
    ['11c27d3babb38956'] = true, -- MG-43
    ['9f80d67a12a7e40f'] = true, -- GR-8
    ['2152d5147b0ac418'] = true, -- MG-206
    ['cd00bdc1149c2928'] = true, -- MG-206 MK2
    ['26e40437ea275296'] = true, -- RL-77
    ['25aa2fd4643cf4ee'] = true, -- FAF-14
    ['cc786f6491fe7e65'] = true, -- StA-X3 W.A.S.P.
    ['d54b9505c0f72873'] = true, -- LAS-98
    ['e8d5f49ad7780e54'] = true, -- PLAS-45
}
