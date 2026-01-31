-- FIXIT: Copilot DON'T send modes like plan, ask for edits, etc. We need to remove it from the header and add a notification
-- FIXIT: Diff is NOT visible when editing
-- FIXIT: check if it's possible to dedupe the _handle_tool_call_update across adapters
-- FIXIT: Check it's possible to always update the tool call in the chat widget when there's body, for all adapters
-- Copilot is sending descriptive message for skill loads, etc, others might also

local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.CopilotRawInput
--- @field path? string file path on the diff tool calls
--- @field new_str? string new string for edit tool calls
--- @field old_str? string old string for edit tool calls
--- @field url? string URL for fetch tool calls
--- @field skill? string skill name for skill tool calls
--- @field command? string command for execute tool calls
--- @field description? string

--- @class agentic.acp.CopilotToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? agentic.acp.CopilotRawInput

--- Copilot-specific adapter that extends ACPClient with Copilot-specific behaviors
--- @class agentic.acp.CopilotACPAdapter : agentic.acp.ACPClient
local CopilotACPAdapter = setmetatable({}, { __index = ACPClient })
CopilotACPAdapter.__index = CopilotACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.CopilotACPAdapter
function CopilotACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, CopilotACPAdapter) --[[@as agentic.acp.CopilotACPAdapter]]

    return self
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.CopilotToolCallMessage
function CopilotACPAdapter:__handle_tool_call(session_id, update)
    -- expected state, copilot is sending an empty content first, followed by the actual content
    if not update.rawInput or vim.tbl_isempty(update.rawInput) then
        return
    end

    local kind = update.kind

    -- -- Detect sub-agent tasks: Copilot sends these as "think" with subagent_type in rawInput
    -- if kind == "think" and update.rawInput.subagent_type then
    --     kind = "SubAgent"
    -- end

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    if kind == "read" or kind == "edit" then
        message.argument = FileSystem.to_smart_path(update.rawInput.path)

        if kind == "edit" then
            local new_string = update.rawInput.new_str or ""
            local old_string = update.rawInput.old_str or ""

            -- -- Copilot might send content when creating new files
            -- new_string = update.rawInput.content or new_string

            message.diff = {
                new = vim.split(new_string, "\n"),
                old = vim.split(old_string, "\n"),
                all = false, -- Copilot doesn't send replace_all info ??
            }
        elseif not message.argument or message.argument == "" then
            message.argument = update.title or update.rawInput.path or ""
        end
    elseif kind == "execute" then
        if update.rawInput.command ~= nil then
            message.argument = update.rawInput.command
            message.body = {
                update.title or update.rawInput.description or "",
            }
        end
    elseif kind == "fetch" then
        if update.rawInput.url ~= nil then
            message.argument = update.rawInput.url
            message.body = {
                update.title or "",
            }
        end
    elseif kind == "other" then
        if update.rawInput.skill ~= nil then
            message.kind = "Skill"
            message.argument = update.rawInput.skill
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function CopilotACPAdapter:__handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
    }

    if update.content and update.content[1] then
        local content = update.content[1]

        if
            content.type == "content"
            and content.content
            and content.content.text
        then
            message.body = vim.split(content.content.text, "\n")
        elseif content.type == "diff" then -- luacheck: ignore 542 -- intentional empty block
            -- ignore on purpose, diffs come only on tool call, not updates
        else
            Logger.debug("Unknown tool call update content type", {
                content_type = content.type,
                content = content.content,
                session_id = session_id,
                tool_call_id = update.toolCallId,
            })
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return CopilotACPAdapter
