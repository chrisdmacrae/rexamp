-- Toggle the Amp HUD beside the focused pane. Load it from
-- ~/.config/rex/init.lua with: dofile(os.getenv("HOME") .. "/Developer/code/amp-rex-hud/init.lua")

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

-- Shift+Cmd+U is taken by Rex's update prompt.
rex.bind("ctrl+cmd+h", "amp_hud")
