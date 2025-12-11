-- Gemini API client for Neovim
-- Provides streaming chat with function calling and RAG support

local M = {}

local json = vim.json

-- API endpoints
local API_BASE = "https://generativelanguage.googleapis.com/v1beta"

-- Available models
M.MODELS = {
  ["gemini-3-pro-preview"] = "gemini-3-pro-preview",
  ["gemini-2.5-flash"] = "gemini-2.5-flash",
  ["gemini-2.5-pro"] = "gemini-2.5-pro",
}

---@class GeminiClient
---@field api_key string
---@field model string
local GeminiClient = {}
GeminiClient.__index = GeminiClient

---Create a new Gemini client
---@param api_key string
---@param model? string
---@return GeminiClient
function M.new(api_key, model)
  local self = setmetatable({}, GeminiClient)
  self.api_key = api_key
  self.model = model or "gemini-2.5-flash"
  return self
end

---Convert internal messages to Gemini Content format
---@param messages table[]
---@return table[]
function M.messages_to_history(messages)
  local contents = {}
  for _, msg in ipairs(messages) do
    local parts = {}

    -- Add text content
    if msg.content and msg.content ~= "" then
      table.insert(parts, { text = msg.content })
    end

    -- Add attachments as inline data
    if msg.attachments then
      for _, att in ipairs(msg.attachments) do
        table.insert(parts, {
          inlineData = {
            mimeType = att.mimeType,
            data = att.data,
          }
        })
      end
    end

    -- Add tool results if present
    if msg.tool_results then
      for _, result in ipairs(msg.tool_results) do
        table.insert(parts, {
          functionResponse = {
            name = result.name,
            response = { result = result.result },
          }
        })
      end
    end

    if #parts > 0 then
      table.insert(contents, {
        role = msg.role == "assistant" and "model" or "user",
        parts = parts,
      })
    end
  end
  return contents
end

---Convert tool definitions to Gemini FunctionDeclaration format
---@param tools table[]
---@return table
function M.tools_to_declarations(tools)
  local declarations = {}
  for _, tool in ipairs(tools) do
    table.insert(declarations, {
      name = tool.name,
      description = tool.description,
      parameters = tool.parameters,
    })
  end
  return { functionDeclarations = declarations }
end

---Make a streaming chat request using vim.system with real-time output
---@param self GeminiClient
---@param opts table
---@return nil
function GeminiClient:chat_stream(opts)
  local messages = opts.messages or {}
  local tools = opts.tools or {}
  local system_prompt = opts.system_prompt or ""
  local on_chunk = opts.on_chunk
  local on_tool_call = opts.on_tool_call
  local on_done = opts.on_done
  local on_error = opts.on_error
  local rag_store_name = opts.rag_store_name

  local contents = M.messages_to_history(messages)

  -- Build request body
  local body = {
    contents = contents,
    generationConfig = {
      temperature = 1.0,
      topP = 0.95,
      topK = 40,
    },
  }

  -- Add system instruction
  if system_prompt and system_prompt ~= "" then
    body.systemInstruction = {
      parts = { { text = system_prompt } }
    }
  end

  -- Add tools
  if #tools > 0 then
    body.tools = { M.tools_to_declarations(tools) }
  end

  -- Add file_search tool if store name provided (for RAG via ragujuary)
  if rag_store_name then
    body.tools = body.tools or {}
    table.insert(body.tools, {
      file_search = {
        file_search_store_names = { rag_store_name },
      }
    })
  end

  local url = string.format(
    "%s/models/%s:streamGenerateContent?alt=sse&key=%s",
    API_BASE, self.model, self.api_key
  )

  local body_json = json.encode(body)

  -- Write body to temp file to avoid shell escaping issues
  local tmp_file = os.tmpname()
  local f = io.open(tmp_file, "w")
  if f then
    f:write(body_json)
    f:close()
  end

  local accumulated_text = ""
  local function_calls = {}
  local rag_sources = {}
  local buffer = ""

  -- Use vim.system for async curl with streaming stdout
  vim.system(
    {
      "curl", "-s", "-N", "-X", "POST", url,
      "-H", "Content-Type: application/json",
      "-d", "@" .. tmp_file,
      "--max-time", "120",
    },
    {
      text = true,
      stdout = function(err, data)
        if err then return end
        if not data then return end

        buffer = buffer .. data

        -- Process complete SSE lines
        while true do
          local line_end = buffer:find("\n")
          if not line_end then break end

          local line = buffer:sub(1, line_end - 1)
          buffer = buffer:sub(line_end + 1)

          if line:match("^data: ") then
            local data_str = line:sub(7)
            if data_str ~= "[DONE]" then
              local ok, parsed = pcall(json.decode, data_str)
              if ok and parsed then
                if parsed.candidates and parsed.candidates[1] then
                  local candidate = parsed.candidates[1]
                  if candidate.content and candidate.content.parts then
                    for _, part in ipairs(candidate.content.parts) do
                      if part.text then
                        accumulated_text = accumulated_text .. part.text
                        if on_chunk then
                          vim.schedule(function()
                            on_chunk({ type = "text", text = part.text })
                          end)
                        end
                      end
                      if part.functionCall then
                        table.insert(function_calls, {
                          name = part.functionCall.name,
                          args = part.functionCall.args or {},
                        })
                      end
                    end
                  end
                  -- Check for grounding/RAG metadata
                if candidate.groundingMetadata and candidate.groundingMetadata.groundingChunks then
                  for _, gc in ipairs(candidate.groundingMetadata.groundingChunks) do
                    if gc.retrievedContext and gc.retrievedContext.uri then
                      table.insert(rag_sources, gc.retrievedContext.uri)
                    end
                  end
                end
                end
                -- Check for error in response
                if parsed.error then
                  if on_error then
                    vim.schedule(function()
                      on_error("API error: " .. (parsed.error.message or data_str))
                    end)
                  end
                  return
                end
              end
            end
          end
        end
      end,
    },
    function(result)
      -- Clean up temp file
      os.remove(tmp_file)

      vim.schedule(function()
        if result.code ~= 0 then
          if on_error then
            on_error("curl failed with code " .. result.code .. ": " .. (result.stderr or ""))
          end
          return
        end

        -- Handle function calls
        if #function_calls > 0 and on_tool_call then
          for _, fc in ipairs(function_calls) do
            on_tool_call(fc)
          end
        end

        -- Report RAG usage
        if #rag_sources > 0 and on_chunk then
          on_chunk({ type = "rag_used", sources = rag_sources })
        end

        if on_done then
          on_done({
            text = accumulated_text,
            function_calls = function_calls,
            rag_sources = rag_sources,
          })
        end
      end)
    end
  )
end

---Chat with tools and handle tool execution loop
---@param self GeminiClient
---@param opts table
function GeminiClient:chat_with_tools(opts)
  local messages = vim.deepcopy(opts.messages or {})
  local tools = opts.tools or {}
  local system_prompt = opts.system_prompt or ""
  local execute_tool = opts.execute_tool
  local on_chunk = opts.on_chunk
  local on_done = opts.on_done
  local on_error = opts.on_error
  local rag_store_name = opts.rag_store_name
  local max_iterations = opts.max_iterations or 10

  local accumulated_text = ""
  local all_tool_calls = {}
  local all_tool_results = {}
  local iteration = 0

  local function do_iteration()
    iteration = iteration + 1
    if iteration > max_iterations then
      if on_error then
        on_error("Maximum tool iterations reached")
      end
      return
    end

    self:chat_stream({
      messages = messages,
      tools = tools,
      system_prompt = system_prompt,
      rag_store_name = rag_store_name,
      on_chunk = on_chunk,
      on_error = on_error,
      on_tool_call = function(fc)
        table.insert(all_tool_calls, fc)
        if on_chunk then
          on_chunk({ type = "tool_call", name = fc.name, args = fc.args })
        end
      end,
      on_done = function(result)
        accumulated_text = accumulated_text .. (result.text or "")

        -- If there are function calls, execute them and continue
        if result.function_calls and #result.function_calls > 0 then
          -- Add assistant message with function calls
          local assistant_parts = {}
          if result.text and result.text ~= "" then
            table.insert(assistant_parts, { text = result.text })
          end
          for _, fc in ipairs(result.function_calls) do
            table.insert(assistant_parts, {
              functionCall = { name = fc.name, args = fc.args }
            })
          end

          -- Execute tools and collect results
          local tool_results = {}
          for _, fc in ipairs(result.function_calls) do
            local tool_result = execute_tool(fc.name, fc.args)
            table.insert(tool_results, {
              name = fc.name,
              result = tool_result,
            })
            table.insert(all_tool_results, {
              name = fc.name,
              args = fc.args,
              result = tool_result,
            })
            if on_chunk then
              on_chunk({ type = "tool_result", name = fc.name, result = tool_result })
            end
          end

          -- Add assistant message
          table.insert(messages, {
            role = "assistant",
            content = result.text or "",
            tool_calls = result.function_calls,
          })

          -- Add tool results as user message
          table.insert(messages, {
            role = "user",
            content = "",
            tool_results = tool_results,
          })

          -- Continue the loop
          do_iteration()
        else
          -- No more function calls, we're done
          if on_done then
            on_done({
              text = accumulated_text,
              tool_calls = all_tool_calls,
              tool_results = all_tool_results,
              rag_sources = result.rag_sources,
            })
          end
        end
      end,
    })
  end

  do_iteration()
end

---Simple non-streaming chat (synchronous)
---@param self GeminiClient
---@param messages table[]
---@param system_prompt? string
---@return string|nil, string|nil
function GeminiClient:chat(messages, system_prompt)
  local contents = M.messages_to_history(messages)

  local body = {
    contents = contents,
    generationConfig = {
      temperature = 1.0,
      topP = 0.95,
      topK = 40,
    },
  }

  if system_prompt and system_prompt ~= "" then
    body.systemInstruction = {
      parts = { { text = system_prompt } }
    }
  end

  local url = string.format(
    "%s/models/%s:generateContent?key=%s",
    API_BASE, self.model, self.api_key
  )

  local body_json = json.encode(body)

  -- Write body to temp file
  local tmp_file = os.tmpname()
  local f = io.open(tmp_file, "w")
  if f then
    f:write(body_json)
    f:close()
  end

  -- Synchronous curl call
  local result = vim.system(
    {
      "curl", "-s", "-X", "POST", url,
      "-H", "Content-Type: application/json",
      "-d", "@" .. tmp_file,
    },
    { text = true }
  ):wait()

  os.remove(tmp_file)

  if result.code ~= 0 then
    return nil, "curl failed: " .. (result.stderr or "unknown")
  end

  local response_body = result.stdout or ""

  local ok, parsed = pcall(json.decode, response_body)
  if not ok then
    return nil, "Failed to parse response: " .. response_body:sub(1, 100)
  end

  if parsed.error then
    return nil, "API error: " .. (parsed.error.message or response_body)
  end

  if parsed.candidates and parsed.candidates[1] then
    local candidate = parsed.candidates[1]
    if candidate.content and candidate.content.parts then
      local text = ""
      for _, part in ipairs(candidate.content.parts) do
        if part.text then
          text = text .. part.text
        end
      end
      return text, nil
    end
  end

  return nil, "No response content"
end

return M
