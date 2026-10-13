-- A SavedVariables file as the game writes it (WTF\Account\<acc>\SavedVariables\DisasterZone.lua), for
-- tests/bosslearn/test_bosslearn.py and tools/bossmods_learned.py. @GRUUL_DS@ is replaced with Gruul's data signature
-- (Core/BossLearnMath.lua Signature) when the test runs, so a data change never breaks the fixture.
DisasterZoneDB = {
	["settings"] = {
		["bossmods"] = {
			["on"] = true,
		},
	},
}
DisasterZoneBossLearnDB = {
	["v"] = 1,
	["pulls"] = {
		["GruulsLair:Gruul"] = {
			{
				["id"] = "GruulsLair:Gruul|Kaelor-Thunderstrike|1760380000",
				["at"] = 1760380000,
				["leader"] = "Kaelor-Thunderstrike",
				["dur"] = 251.3,
				["kill"] = false,
				["clean"] = true,
				["ds"] = "@GRUUL_DS@",
				["av"] = "1.4.2",
				["from"] = "me",
				["src"] = 2,
				["o"] = {
					["growth"] = { 30.1, 60.2, 90 },
					["slam"] = { 34.2 },
					["shatter"] = { 44.3 },
					["reverb"] = { 60.4 },
				},
				["g"] = {
					["shatter"] = { 34.2 },
				},
				["nf"] = { "cavein" },
				["u"] = {
					{ ["id"] = 33572, ["n"] = 40, ["t"] = 2, ["name"] = "Gronn Lord's Grasp" },
					{ ["id"] = 36241, ["n"] = 4, ["t"] = 50.1, ["name"] = "Cave In" },
				},
				["y"] = {
					{ ["t"] = 1, ["n"] = 1, ["text"] = "Come... and die.", ["kind"] = "yell" },
				},
			},
			{
				["id"] = "GruulsLair:Gruul|Kaelor-Thunderstrike|1760381000",
				["at"] = 1760381000,
				["leader"] = "Kaelor-Thunderstrike",
				["dur"] = 180,
				["kill"] = false,
				["clean"] = true,
				["ds"] = "@GRUUL_DS@",
				["av"] = "1.4.2",
				["from"] = "Bob-Thunderstrike",
				["src"] = 1,
				["o"] = {
					["growth"] = { 29.9, 60 },
					["slam"] = { 35 },
					["shatter"] = { 45 },
					["reverb"] = { 61 },
				},
				["g"] = {
					["shatter"] = { 35 },
				},
				["nf"] = { "cavein" },
				["u"] = {
					{ ["id"] = 33572, ["n"] = 35, ["t"] = 2.2 },
					{ ["id"] = 36241, ["n"] = 3, ["t"] = 48.8 },
				},
				["y"] = {
					{ ["t"] = 1.1, ["n"] = 1, ["text"] = "Come... and die.", ["kind"] = "yell" },
				},
			},
			{
				["id"] = "GruulsLair:Gruul|Kaelor-Thunderstrike|1760382000",
				["at"] = 1760382000,
				["leader"] = "Kaelor-Thunderstrike",
				["dur"] = 262.5,
				["kill"] = true,
				["clean"] = true,
				["ds"] = "@GRUUL_DS@",
				["av"] = "1.4.2",
				["from"] = "me",
				["src"] = 1,
				["o"] = {
					["growth"] = { 30.3, 60.5, 90.4 },
					["slam"] = { 36.8 },
					["shatter"] = { 46.9 },
					["reverb"] = { 62 },
				},
				["g"] = {
					["shatter"] = { 36.8 },
				},
				["nf"] = { "cavein" },
				["u"] = {
					{ ["id"] = 33572, ["n"] = 41, ["t"] = 1.9, ["name"] = "Gronn Lord's Grasp" },
					{ ["id"] = 36241, ["n"] = 5, ["t"] = 51, ["name"] = "Cave In" },
				},
			},
			{
				["id"] = "GruulsLair:Gruul|Kaelor-Thunderstrike|1750000000",
				["at"] = 1750000000,
				["leader"] = "Kaelor-Thunderstrike",
				["dur"] = 200,
				["kill"] = true,
				["clean"] = true,
				["ds"] = "deadbeef",
				["av"] = "1.4.2",
				["from"] = "me",
				["src"] = 1,
				["o"] = {
					["slam"] = { 80 },
				},
			},
		},
	},
	["learned"] = {
	},
	["review"] = {
		["decisions"] = {
			["GruulsLair:Gruul"] = {
				["cast:33572"] = { ["ignore"] = true, ["what"] = "Gronn Lord's Grasp", ["at"] = 1760390000 },
			},
		},
		["suggest"] = {
		},
	},
	["log"] = {
		"2026-10-13 21:42 GruulsLair:Gruul pull 5: recording stopped (2,000 events)",
	},
}
