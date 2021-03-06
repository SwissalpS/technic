-- See also technic/doc/api.md

technic.networks = {}
technic.cables = {}
technic.redundant_warn = {}

local overload_reset_time = tonumber(minetest.settings:get("technic.overload_reset_time") or "20")
local overloaded_networks = {}
local function overload_network(network_id)
	overloaded_networks[network_id] = minetest.get_us_time() + (overload_reset_time * 1000 * 1000)
end
local function reset_overloaded(network_id)
	local remaining = math.max(0, overloaded_networks[network_id] - minetest.get_us_time())
	if remaining == 0 then
		-- Clear cache, remove overload and restart network
		technic.remove_network(network_id)
		overloaded_networks[network_id] = nil
	end
	-- Returns 0 when network reset or remaining time if reset timer has not expired yet
	return remaining
end

local switch_max_range = tonumber(minetest.settings:get("technic.switch_max_range") or "256")

local mesecons_path = minetest.get_modpath("mesecons")
local digilines_path = minetest.get_modpath("digilines")

local S = technic.getter

local cable_entry = "^technic_cable_connection_overlay.png"

minetest.register_craft({
	output = "technic:switching_station",
	recipe = {
		{"",                     "technic:lv_transformer", ""},
		{"default:copper_ingot", "technic:machine_casing", "default:copper_ingot"},
		{"technic:lv_cable",     "technic:lv_cable",       "technic:lv_cable"}
	}
})

local mesecon_def
if mesecons_path then
	mesecon_def = {effector = {
		rules = mesecon.rules.default,
	}}
end

minetest.register_node("technic:switching_station",{
	description = S("Switching Station"),
	tiles  = {
		"technic_water_mill_top_active.png",
		"technic_water_mill_top_active.png"..cable_entry,
		"technic_water_mill_top_active.png",
		"technic_water_mill_top_active.png",
		"technic_water_mill_top_active.png",
		"technic_water_mill_top_active.png"},
	groups = {snappy=2, choppy=2, oddly_breakable_by_hand=2, technic_all_tiers=1},
	connect_sides = {"bottom"},
	sounds = default.node_sound_wood_defaults(),
	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		meta:set_string("infotext", S("Switching Station"))
		local network_id = technic.sw_pos2network(pos)
		local net_sw_pos = network_id and technic.network2sw_pos(network_id)
		local net_sw_node = net_sw_pos and minetest.get_node_or_nil(net_sw_pos)
		if net_sw_node then
			-- There's already network with same id, check if it already has active switching station
			if net_sw_node.name == "technic:switching_station" then
				-- Another switch found set active to 0 for this switch if another is already active
				local net_sw_meta = minetest.get_meta(net_sw_pos)
				meta:set_string("active", net_sw_meta:get_int("active") == 1 and 0 or 1)
			else
				-- Network switching station disappeared, cleanup caches and start new network
				technic.remove_network(network_id)
				meta:set_string("active", 1)
			end
		else
			-- Clean start, not previous networks, no other switching stations
			meta:set_string("active", 1)
		end
		meta:set_string("channel", "switching_station"..minetest.pos_to_string(pos))
		meta:set_string("formspec", "field[channel;Channel;${channel}]")
		local poshash = minetest.hash_node_position(pos)
		technic.redundant_warn.poshash = nil
	end,
	after_dig_node = function(pos)
		pos.y = pos.y - 1
		local poshash = minetest.hash_node_position(pos)
		technic.redundant_warn.poshash = nil
	end,
	on_receive_fields = function(pos, formname, fields, sender)
		if not fields.channel then
			return
		end
		local plname = sender:get_player_name()
		if minetest.is_protected(pos, plname) then
			minetest.record_protection_violation(pos, plname)
			return
		end
		local meta = minetest.get_meta(pos)
		meta:set_string("channel", fields.channel)
	end,
	mesecons = mesecon_def,
	digiline = {
		receptor = {
			rules = technic.digilines.rules,
			action = function() end
		},
		effector = {
			rules = technic.digilines.rules,
			action = function(pos, node, channel, msg)
				if msg ~= "GET" and msg ~= "get" then
					return
				end
				local meta = minetest.get_meta(pos)
				if channel ~= meta:get_string("channel") then
					return
				end
				digilines.receptor_send(pos, technic.digilines.rules, channel, {
					supply = meta:get_int("supply"),
					demand = meta:get_int("demand"),
					lag = meta:get_int("lag")
				})
			end
		},
	},
})

--------------------------------------------------
-- Functions to traverse the electrical network
--------------------------------------------------
local function flatten(map)
	local list = {}
	for key, value in pairs(map) do
		list[#list + 1] = value
	end
	return list
end

local function attach_network_machine(network_id, pos)
	local pos_hash = minetest.hash_node_position(pos)
	local net_id_old = technic.cables[pos_hash]
	if net_id_old == nil then
		technic.cables[pos_hash] = network_id
	elseif net_id_old ~= network_id then
		-- do not allow running pos from multiple networks, also disable switch
		overload_network(network_id, pos)
		overload_network(net_id_old, pos)
		technic.cables[pos_hash] = network_id
		local meta = minetest.get_meta(pos)
		meta:set_string("infotext",S("Network Overloaded"))
	end
end

-- Add a wire node to the LV/MV/HV network
local function add_network_node(nodes, pos, network_id)
	local node_id = minetest.hash_node_position(pos)
	technic.cables[node_id] = network_id
	if nodes[node_id] then
		return false
	end
	nodes[node_id] = pos
	return true
end

local function add_cable_node(nodes, pos, network_id, queue)
	if add_network_node(nodes, pos, network_id) then
		queue[#queue + 1] = pos
	end
end

-- Generic function to add found connected nodes to the right classification array
local function check_node_subp(PR_nodes, RE_nodes, BA_nodes, SP_nodes, all_nodes, pos, machines, tier, sw_pos, from_below, network_id, queue)

	local distance_to_switch = vector.distance(pos, sw_pos)
	if distance_to_switch > switch_max_range then
		-- max range exceeded
		return
	end

	technic.get_or_load_node(pos)
	local name = minetest.get_node(pos).name

	if technic.is_tier_cable(name, tier) then
		add_cable_node(all_nodes, pos, network_id, queue)
	elseif machines[name] then
		--dprint(name.." is a "..machines[name])

		if     machines[name] == technic.producer then
			attach_network_machine(network_id, pos)
			add_network_node(PR_nodes, pos, network_id)
		elseif machines[name] == technic.receiver then
			attach_network_machine(network_id, pos)
			add_network_node(RE_nodes, pos, network_id)
		elseif machines[name] == technic.producer_receiver then
			--attach_network_machine(network_id, pos)
			add_network_node(PR_nodes, pos, network_id)
			add_network_node(RE_nodes, pos, network_id)
		elseif machines[name] == "SPECIAL" and
				(pos.x ~= sw_pos.x or pos.y ~= sw_pos.y or pos.z ~= sw_pos.z) and
				from_below then
			-- Another switching station -> disable it
			attach_network_machine(network_id, pos)
			add_network_node(SP_nodes, pos, network_id)
			local meta = minetest.get_meta(pos)
			meta:set_int("active", 0)
		elseif machines[name] == technic.battery then
			attach_network_machine(network_id, pos)
			add_network_node(BA_nodes, pos, network_id)
		end

		technic.touch_node(tier, pos, 2) -- Touch node
	end
end

-- Traverse a network given a list of machines and a cable type name
local function traverse_network(PR_nodes, RE_nodes, BA_nodes, SP_nodes, all_nodes, pos, machines, tier, sw_pos, network_id, queue)
	local positions = {
		{x=pos.x+1, y=pos.y,   z=pos.z},
		{x=pos.x-1, y=pos.y,   z=pos.z},
		{x=pos.x,   y=pos.y+1, z=pos.z},
		{x=pos.x,   y=pos.y-1, z=pos.z},
		{x=pos.x,   y=pos.y,   z=pos.z+1},
		{x=pos.x,   y=pos.y,   z=pos.z-1}}
	for i, cur_pos in pairs(positions) do
		check_node_subp(PR_nodes, RE_nodes, BA_nodes, SP_nodes, all_nodes, cur_pos, machines, tier, sw_pos, i == 3, network_id, queue)
	end
end

function technic.remove_network(network_id)
	local cables = technic.cables
	for pos_hash,cable_net_id in pairs(cables) do
		if cable_net_id == network_id then
			cables[pos_hash] = nil
		end
	end
	technic.networks[network_id] = nil
end

function technic.sw_pos2network(pos)
	return pos and technic.cables[minetest.hash_node_position({x=pos.x,y=pos.y-1,z=pos.z})]
end

function technic.pos2network(pos)
	return pos and technic.cables[minetest.hash_node_position(pos)]
end

function technic.network2pos(network_id)
	return network_id and minetest.get_position_from_hash(network_id)
end

function technic.network2sw_pos(network_id)
	-- Return switching station position for network.
	-- It is not guaranteed that position actually contains switching station.
	local sw_pos = minetest.get_position_from_hash(network_id)
	sw_pos.y = sw_pos.y + 1
	return sw_pos
end

local node_timeout = {}

function technic.get_timeout(tier, pos)
	if node_timeout[tier] == nil then
		-- it is normal that some multi tier nodes always drop here when checking all LV, MV and HV tiers
		return 0
	end
	return node_timeout[tier][minetest.hash_node_position(pos)] or 0
end

function technic.touch_node(tier, pos, timeout)
	if node_timeout[tier] == nil then
		-- this should get built up during registration
		node_timeout[tier] = {}
	end
	node_timeout[tier][minetest.hash_node_position(pos)] = timeout or 2
end

local function touch_nodes(list, tier)
	local touch_node = technic.touch_node
	for _, pos in ipairs(list) do
		touch_node(tier, pos, 2) -- Touch node
	end
end

local function get_network(network_id, sw_pos, pos1, tier)
	local cached = technic.networks[network_id]
	if cached and cached.tier == tier then
		touch_nodes(cached.PR_nodes, tier)
		touch_nodes(cached.BA_nodes, tier)
		touch_nodes(cached.RE_nodes, tier)
		for _, pos in ipairs(cached.SP_nodes) do
			local meta = minetest.get_meta(pos)
			meta:set_int("active", 0)
			meta:set_string("active_pos", minetest.serialize(sw_pos))
			technic.touch_node(tier, pos, 2) -- Touch node
		end
		return cached.PR_nodes, cached.BA_nodes, cached.RE_nodes
	end
	local PR_nodes = {}
	local BA_nodes = {}
	local RE_nodes = {}
	local SP_nodes = {}
	local all_nodes = {}
	local queue = {}
	add_cable_node(all_nodes, pos1, network_id, queue)
	while next(queue) do
		local to_visit = {}
		for _, pos in ipairs(queue) do
			traverse_network(PR_nodes, RE_nodes, BA_nodes, SP_nodes, all_nodes,
					pos, technic.machines[tier], tier, sw_pos, network_id, to_visit)
		end
		queue = to_visit
	end
	PR_nodes = flatten(PR_nodes)
	BA_nodes = flatten(BA_nodes)
	RE_nodes = flatten(RE_nodes)
	SP_nodes = flatten(SP_nodes)
	technic.networks[network_id] = {tier = tier, all_nodes = all_nodes, SP_nodes = SP_nodes,
			PR_nodes = PR_nodes, RE_nodes = RE_nodes, BA_nodes = BA_nodes}
	return PR_nodes, BA_nodes, RE_nodes
end

-----------------------------------------------
-- The action code for the switching station --
-----------------------------------------------

technic.powerctrl_state = true

minetest.register_chatcommand("powerctrl", {
	params = "state",
	description = "Enables or disables technic's switching station ABM",
	privs = { basic_privs = true },
	func = function(name, state)
		if state == "on" then
			technic.powerctrl_state = true
		else
			technic.powerctrl_state = false
		end
	end
})

-- Run all the nodes
local function run_nodes(list, run_stage)
	for _, pos in ipairs(list) do
		technic.get_or_load_node(pos)
		local node = minetest.get_node_or_nil(pos)
		if node and node.name then
			local nodedef = minetest.registered_nodes[node.name]
			if nodedef and nodedef.technic_run then
				nodedef.technic_run(pos, node, run_stage)
			end
		end
	end
end

function technic.switching_station_run(pos)
	if not technic.powerctrl_state then return end

	local t0 	       = minetest.get_us_time()
	local meta             = minetest.get_meta(pos)
	local meta1
	local pos1             = {}

	local tier      = ""
	local PR_nodes
	local BA_nodes
	local RE_nodes
	local machine_name = S("Switching Station")

	-- Which kind of network are we on:
	pos1 = {x=pos.x, y=pos.y-1, z=pos.z}

	--Disable if necessary
	if meta:get_int("active") ~= 1 then
		meta:set_string("infotext",S("%s Already Present"):format(machine_name))

		local poshash = minetest.hash_node_position(pos)

		if not technic.redundant_warn[poshash] then
			technic.redundant_warn[poshash] = true
			print("[TECHNIC] Warning: redundant switching station found near "..minetest.pos_to_string(pos))
		end
		return
	end

	local network_id = minetest.hash_node_position(pos1)
	-- Check if network is overloaded / conflicts with another network
	if overloaded_networks[network_id] then
		local remaining = reset_overloaded(network_id)
		if remaining > 0 then
			meta:set_string("infotext",S("%s Network Overloaded, Restart in %dms"):format(machine_name, remaining / 1000))
			-- Set switching station supply value to zero to clean up power monitor supply info
			meta:set_int("supply",0)
			return
		end
		meta:set_string("infotext",S("%s Restarting Network"):format(machine_name))
		return
	end

	local name = minetest.get_node(pos1).name
	local tier = technic.get_cable_tier(name)
	if tier then
		PR_nodes, BA_nodes, RE_nodes = get_network(network_id, pos, pos1, tier)
		if overloaded_networks[network_id] then return end
	else
		--dprint("Not connected to a network")
		meta:set_string("infotext", S("%s Has No Network"):format(machine_name))
		return
	end

	run_nodes(PR_nodes, technic.producer)
	run_nodes(RE_nodes, technic.receiver)
	run_nodes(BA_nodes, technic.battery)

	-- Strings for the meta data
	local eu_demand_str    = tier.."_EU_demand"
	local eu_input_str     = tier.."_EU_input"
	local eu_supply_str    = tier.."_EU_supply"

	-- Distribute charge equally across multiple batteries.
	local charge_total = 0
	local battery_count = 0

	local BA_charge = 0
	local BA_charge_max = 0

	for n, pos1 in pairs(BA_nodes) do
		meta1 = minetest.get_meta(pos1)
		local charge = meta1:get_int("internal_EU_charge")
		local charge_max = meta1:get_int("internal_EU_charge_max")

		BA_charge = BA_charge + charge
		BA_charge_max = BA_charge_max + charge_max

		if (meta1:get_int(eu_demand_str) ~= 0) then
			charge_total = charge_total + charge
			battery_count = battery_count + 1
		end
	end

	local charge_distributed = math.floor(charge_total / battery_count)

	for n, pos1 in pairs(BA_nodes) do
		meta1 = minetest.get_meta(pos1)

		if (meta1:get_int(eu_demand_str) ~= 0) then
			meta1:set_int("internal_EU_charge", charge_distributed)
		end
	end

	-- Get all the power from the PR nodes
	local PR_eu_supply = 0 -- Total power
	for _, pos1 in pairs(PR_nodes) do
		meta1 = minetest.get_meta(pos1)
		PR_eu_supply = PR_eu_supply + meta1:get_int(eu_supply_str)
	end
	--dprint("Total PR supply:"..PR_eu_supply)

	-- Get all the demand from the RE nodes
	local RE_eu_demand = 0
	for _, pos1 in pairs(RE_nodes) do
		meta1 = minetest.get_meta(pos1)
		RE_eu_demand = RE_eu_demand + meta1:get_int(eu_demand_str)
	end
	--dprint("Total RE demand:"..RE_eu_demand)

	-- Get all the power from the BA nodes
	local BA_eu_supply = 0
	for _, pos1 in pairs(BA_nodes) do
		meta1 = minetest.get_meta(pos1)
		BA_eu_supply = BA_eu_supply + meta1:get_int(eu_supply_str)
	end
	--dprint("Total BA supply:"..BA_eu_supply)

	-- Get all the demand from the BA nodes
	local BA_eu_demand = 0
	for _, pos1 in pairs(BA_nodes) do
		meta1 = minetest.get_meta(pos1)
		BA_eu_demand = BA_eu_demand + meta1:get_int(eu_demand_str)
	end
	--dprint("Total BA demand:"..BA_eu_demand)

	meta:set_string("infotext", S("@1. Supply: @2 Demand: @3",
			machine_name, technic.EU_string(PR_eu_supply),
			technic.EU_string(RE_eu_demand)))

	-- If mesecon signal and power supply or demand changed then
	-- send them via digilines.
	if mesecons_path and digilines_path and mesecon.is_powered(pos) then
		if PR_eu_supply ~= meta:get_int("supply") or
				RE_eu_demand ~= meta:get_int("demand") then
			local channel = meta:get_string("channel")
			digilines.receptor_send(pos, technic.digilines.rules, channel, {
				supply = PR_eu_supply,
				demand = RE_eu_demand
			})
		end
	end

	-- Data that will be used by the power monitor
	meta:set_int("supply",PR_eu_supply)
	meta:set_int("demand",RE_eu_demand)
	meta:set_int("battery_count",#BA_nodes)
	meta:set_int("battery_charge",BA_charge)
	meta:set_int("battery_charge_max",BA_charge_max)

	-- If the PR supply is enough for the RE demand supply them all
	if PR_eu_supply >= RE_eu_demand then
	--dprint("PR_eu_supply"..PR_eu_supply.." >= RE_eu_demand"..RE_eu_demand)
		for _, pos1 in pairs(RE_nodes) do
			meta1 = minetest.get_meta(pos1)
			local eu_demand = meta1:get_int(eu_demand_str)
			meta1:set_int(eu_input_str, eu_demand)
		end
		-- We have a surplus, so distribute the rest equally to the BA nodes
		-- Let's calculate the factor of the demand
		PR_eu_supply = PR_eu_supply - RE_eu_demand
		local charge_factor = 0 -- Assume all batteries fully charged
		if BA_eu_demand > 0 then
			charge_factor = PR_eu_supply / BA_eu_demand
		end
		for n, pos1 in pairs(BA_nodes) do
			meta1 = minetest.get_meta(pos1)
			local eu_demand = meta1:get_int(eu_demand_str)
			meta1:set_int(eu_input_str, math.floor(eu_demand * charge_factor))
			--dprint("Charging battery:"..math.floor(eu_demand*charge_factor))
		end
		local t1 = minetest.get_us_time()
		local diff = t1 - t0
		if diff > 50000 then
			minetest.log("warning", "[technic] [+supply] switching station abm took " .. diff .. " us at " .. minetest.pos_to_string(pos))
		end

		return
	end

	-- If the PR supply is not enough for the RE demand we will discharge the batteries too
	if PR_eu_supply + BA_eu_supply >= RE_eu_demand then
		--dprint("PR_eu_supply "..PR_eu_supply.."+BA_eu_supply "..BA_eu_supply.." >= RE_eu_demand"..RE_eu_demand)
		for _, pos1 in pairs(RE_nodes) do
			meta1  = minetest.get_meta(pos1)
			local eu_demand = meta1:get_int(eu_demand_str)
			meta1:set_int(eu_input_str, eu_demand)
		end
		-- We have a deficit, so distribute to the BA nodes
		-- Let's calculate the factor of the supply
		local charge_factor = 0 -- Assume all batteries depleted
		if BA_eu_supply > 0 then
			charge_factor = (PR_eu_supply - RE_eu_demand) / BA_eu_supply
		end
		for n,pos1 in pairs(BA_nodes) do
			meta1 = minetest.get_meta(pos1)
			local eu_supply = meta1:get_int(eu_supply_str)
			meta1:set_int(eu_input_str, math.floor(eu_supply * charge_factor))
			--dprint("Discharging battery:"..math.floor(eu_supply*charge_factor))
		end
		local t1 = minetest.get_us_time()
		local diff = t1 - t0
		if diff > 50000 then
			minetest.log("warning", "[technic] [-supply] switching station abm took " .. diff .. " us at " .. minetest.pos_to_string(pos))
		end

		return
	end

	-- If the PR+BA supply is not enough for the RE demand: Power only the batteries
	local charge_factor = 0 -- Assume all batteries fully charged
	if BA_eu_demand > 0 then
		charge_factor = PR_eu_supply / BA_eu_demand
	end
	for n, pos1 in pairs(BA_nodes) do
		meta1 = minetest.get_meta(pos1)
		local eu_demand = meta1:get_int(eu_demand_str)
		meta1:set_int(eu_input_str, math.floor(eu_demand * charge_factor))
	end
	for n, pos1 in pairs(RE_nodes) do
		meta1 = minetest.get_meta(pos1)
		meta1:set_int(eu_input_str, 0)
	end

	local t1 = minetest.get_us_time()
	local diff = t1 - t0
	if diff > 50000 then
		minetest.log("warning", "[technic] switching station abm took " .. diff .. " us at " .. minetest.pos_to_string(pos))
	end


end

-- Timeout ABM
-- Timeout for a node in case it was disconnected from the network
-- A node must be touched by the station continuously in order to function
local function switching_station_timeout_count(pos, tier)
	local timeout = technic.get_timeout(tier, pos)
	if timeout <= 0 then
		local meta = minetest.get_meta(pos)
		meta:set_int(tier.."_EU_input", 0) -- Not needed anymore <-- actually, it is for supply converter
		return true
	else
		technic.touch_node(tier, pos, timeout - 1)
		return false
	end
end
minetest.register_abm({
	label = "Machines: timeout check",
	nodenames = {"group:technic_machine"},
	interval   = 1.9,
	chance     = 3,
	action = function(pos, node, active_object_count, active_object_count_wider)
		for tier, machines in pairs(technic.machines) do
			if machines[node.name] and switching_station_timeout_count(pos, tier) then
				local nodedef = minetest.registered_nodes[node.name]
				if nodedef and nodedef.technic_disabled_machine_name then
					node.name = nodedef.technic_disabled_machine_name
					minetest.swap_node(pos, node)
				elseif nodedef and nodedef.technic_on_disable then
					nodedef.technic_on_disable(pos, node)
				end
				if nodedef then
					local meta = minetest.get_meta(pos)
					meta:set_string("infotext", S("%s Has No Network"):format(nodedef.description))
				end
			end
		end
	end,
})

--Re-enable disabled switching station if necessary, similar to the timeout above
minetest.register_abm({
	label = "Machines: re-enable check",
	nodenames = {"technic:switching_station"},
	interval   = 1,
	chance     = 1,
	action = function(pos, node, active_object_count, active_object_count_wider)
		local pos1 = {x=pos.x,y=pos.y-1,z=pos.z}
		local tier = technic.get_cable_tier(minetest.get_node(pos1).name)
		if not tier then return end
		if switching_station_timeout_count(pos, tier) then
			local meta = minetest.get_meta(pos)
			meta:set_int("active",1)
		end
	end,
})

for tier, machines in pairs(technic.machines) do
	-- SPECIAL will not be traversed
	technic.register_machine(tier, "technic:switching_station", "SPECIAL")
end
