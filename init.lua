-- Rex actions for amp-rex-hud. Load this file from ~/.config/rex/init.lua with
-- dofile(os.getenv("HOME") .. "/Developer/tools/rexamp/init.lua"), then run
-- rex config reload.
--
--   Shift+Cmd+H  Toggle Amp HUD     the live HUD in a split beside the pane
--   Shift+Cmd+A  Switch to Agent…   pick an agent pane and show it
--   Shift+Cmd+R  Reply to Agent…    answer an agent's question or prompt
--
-- The last two are also buttons at the bottom of the HUD.

local HUD_LABEL = "amp-hud"
local HUD_BIN = os.getenv("HOME") .. "/.local/bin/amp-rex-hud"

rex.action{
  name     = "amp_hud",
  title    = "Toggle Amp HUD",
  category = "Amp",
  keywords = "amp claude codex usage credits agents hud",
  run      = function(ctx, args)
    local blocks, err = rex.session.list_blocks{}
    if err ~= nil then error(err, 0) end

    local anchor = ctx.block_id
    local window
    for _, b in ipairs(blocks.blocks or {}) do
      if b.block_id == anchor then window = b.window_id end
    end
    for _, b in ipairs(blocks.blocks or {}) do
      if b.label == HUD_LABEL and b.window_id == window then
        local r, e = rex.exec({ "rex", "block", "close", "-s", ctx.session_id, b.block_id }, { timeout = 10 })
        if r == nil then error(e, 0) end
        if not r.ok then error(r.stderr, 0) end
        return { closed = b.block_id }
      end
    end

    local split, e = rex.session.new_split{
      anchor_id = anchor,
      direction = "horizontal",
      side      = "after",
      ratio     = 0.62,
      focus     = false,
      layout    = { block = {
        flavor  = "com.superlogical.terminal.shell",
        label   = HUD_LABEL,
        options = { command = { HUD_BIN } },
      } },
    }
    if e ~= nil then error(e, 0) end
    return { opened = split.block_ids[1] }
  end,
}

-- hud runs amp-rex-hud -once -json, which reads the Rex panes once, and
-- returns what it printed. With cmd, it runs that command on them instead.
local function hud(ctx, cmd)
  local argv = { HUD_BIN, "-once", "-json" }
  if cmd ~= nil then
    if ctx.client_id ~= nil then
      table.insert(argv, "-client")
      table.insert(argv, ctx.client_id) -- show panes in the app that asked
    end
    table.insert(argv, "-cmd")
    table.insert(argv, rex.json.encode(cmd))
  end
  local r, err = rex.exec(argv, { timeout = 30 })
  if r == nil then error(err, 0) end
  if not r.ok then
    local msg = r.stderr:gsub("%s+$", "")
    error(msg ~= "" and msg or "amp-rex-hud failed", 0)
  end
  return r.stdout
end

-- Agents that need you come first, then the HUD's own order.
local RANK = { blocked = 1, error = 2, done = 3, working = 4, idle = 5 }
local STATE = { blocked = "needs you", error = "failed" }

local function agents(ctx)
  local snap, err = rex.json.decode(hud(ctx))
  if snap == nil then error(err, 0) end
  local list = snap.agents or {}
  if #list == 0 and snap.errors and snap.errors.rex then error(snap.errors.rex, 0) end
  for i, a in ipairs(list) do a.order = i end
  table.sort(list, function(a, b)
    local ra, rb = RANK[a.state] or 9, RANK[b.state] or 9
    if ra ~= rb then return ra < rb end
    return a.order < b.order
  end)
  return list
end

-- pickAgent asks which agent to act on and returns it, or nil.
local function pickAgent(ctx, title, confirm)
  local list = agents(ctx)
  if #list == 0 then
    rex.log("info", "No agents are running in Rex.")
    return nil
  end
  local items, byBlock = {}, {}
  for _, a in ipairs(list) do
    local where = { a.session }
    local home, cwd = os.getenv("HOME"), a.cwd or ""
    if cwd:sub(1, #home) == home then cwd = "~" .. cwd:sub(#home + 1) end
    if cwd ~= "" then table.insert(where, cwd) end
    table.insert(where, a.host)
    table.insert(items, {
      id       = a.block,
      title    = a.name .. ": " .. a.task,
      subtitle = table.concat(where, " · "),
      icon     = "terminal",
      detail   = STATE[a.state] or a.state,
    })
    byBlock[a.block] = a
  end
  local id, why = rex.ui.pick{
    title       = title,
    placeholder = "Filter agents",
    confirm     = confirm,
    items       = items,
  }
  if id == nil then
    if why ~= "cancelled" then rex.log("warn", title .. ": " .. why) end
    return nil
  end
  return byBlock[id]
end

rex.action{
  name        = "amp_agents",
  title       = "Switch to Agent…",
  description = "Show an Amp, Claude Code, Codex, or Foundation Models pane, with the ones that need you first.",
  category    = "Amp",
  keywords    = "amp claude codex agents panes jump go",
  run         = function(ctx, args)
    local a = pickAgent(ctx, "Switch to agent", "Show")
    if a == nil then return end
    hud(ctx, { op = "focus", block = a.block })
    return { focused = a.block }
  end,
}

rex.action{
  name        = "amp_reply",
  title       = "Reply to Agent…",
  description = "Answer an agent's prompt or question without leaving this pane.",
  category    = "Amp",
  keywords    = "amp claude codex agents answer respond approve message",
  run         = function(ctx, args)
    local a = pickAgent(ctx, "Reply to agent", "Reply")
    if a == nil then return end

    -- A menu on screen, such as a permission prompt: choose one of its
    -- options, or type an answer instead.
    local p = a.prompt
    if p ~= nil and p.options ~= nil and #p.options > 0 then
      local items = {}
      for i, o in ipairs(p.options) do
        table.insert(items, { id = tostring(i - 1), title = o.label, subtitle = o.detail, detail = o.key })
      end
      local choice, why = rex.ui.pick{
        title       = p.question ~= "" and p.question or (a.name .. " asks"),
        placeholder = "Choose, or type an answer",
        items       = items,
        allow_other = true,
      }
      if choice == nil then
        if why ~= "cancelled" then rex.log("warn", "Reply to agent: " .. why) end
        return
      end
      if type(choice) == "table" then
        hud(ctx, { op = "reply", block = a.block, text = choice.text })
        return { replied = a.block }
      end
      hud(ctx, { op = "choose", block = a.block, option = tonumber(choice) })
      return { chose = a.block, option = tonumber(choice) }
    end

    local text, why = rex.ui.input{
      title       = (a.question and a.question ~= "") and a.question or ("Message " .. a.name .. ": " .. a.task),
      placeholder = "Type a reply for " .. a.name,
      confirm     = "Send to " .. a.name,
    }
    if text == nil then
      if why ~= "cancelled" then rex.log("warn", "Reply to agent: " .. why) end
      return
    end
    if text:match("^%s*$") then return end
    hud(ctx, { op = "reply", block = a.block, text = text })
    return { replied = a.block }
  end,
}

-- Shift+Cmd+U is taken by Rex's update prompt; A, R, and H are free.
rex.bind("shift+cmd+h", "amp_hud")
rex.bind("shift+cmd+a", "amp_agents")
rex.bind("shift+cmd+r", "amp_reply")
