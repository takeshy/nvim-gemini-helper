-- Gemini API client for Neovim
-- Provides streaming chat with function calling and RAG support

local M = {}

local json = vim.json

-- API endpoints
local API_BASE = "https://generativelanguage.googleapis.com/v1beta"

-- API Plans
M.API_PLANS = { "paid", "free" }
M.DEFAULT_API_PLAN = "paid"

-- Default model
M.DEFAULT_MODEL = "gemini-3-flash-preview"

-- Paid tier models
M.PAID_MODELS = {
  {
    name = "gemini-3-flash-preview",
    display_name = "Gemini 3 Flash Preview",
    description = "Latest fast model with 1M context (recommended)",
  },
  {
    name = "gemini-3-pro-preview",
    display_name = "Gemini 3 Pro Preview",
    description = "Latest flagship model with 1M context",
  },
  {
    name = "gemini-2.5-flash-lite",
    display_name = "Gemini 2.5 Flash Lite",
    description = "Lightweight flash model",
  },
}

-- Free tier models
M.FREE_MODELS = {
  {
    name = "gemini-2.5-flash",
    display_name = "Gemini 2.5 Flash",
    description = "Free tier fast model",
  },
  {
    name = "gemini-2.5-flash-lite",
    display_name = "Gemini 2.5 Flash Lite",
    description = "Free tier lightweight model",
  },
  {
    name = "gemini-3-flash-preview",
    display_name = "Gemini 3 Flash Preview",
    description = "Free tier preview model",
  },
  {
    name = "gemma-3-27b-it",
    display_name = "Gemma 3 27B",
    description = "Free Gemma model (no function calling)",
    no_function_calling = true,
  },
  {
    name = "gemma-3-12b-it",
    display_name = "Gemma 3 12B",
    description = "Free Gemma model (no function calling)",
    no_function_calling = true,
  },
  {
    name = "gemma-3-4b-it",
    display_name = "Gemma 3 4B",
    description = "Free Gemma model (no function calling)",
    no_function_calling = true,
  },
}

-- Legacy MODEL_INFO for backwards compatibility (defaults to paid)
M.MODEL_INFO = M.PAID_MODELS

---Get available models based on API plan
---@param api_plan string "paid" or "free"
---@return table[]
function M.get_models_for_plan(api_plan)
  return api_plan == "free" and M.FREE_MODELS or M.PAID_MODELS
end

---Check if model is allowed for the given plan
---@param api_plan string
---@param model_name string
---@return boolean
function M.is_model_allowed_for_plan(api_plan, model_name)
  local models = M.get_models_for_plan(api_plan)
  for _, m in ipairs(models) do
    if m.name == model_name then
      return true
    end
  end
  return false
end

---Check if model supports function calling
---@param model_name string
---@return boolean
function M.supports_function_calling(model_name)
  -- gemma models don't support function calling
  return not model_name:match("^gemma")
end

-- CLI Model info (for UI, loaded from cli_provider module)
M.CLI_MODEL_INFO = {
  {
    name = "gemini-cli",
    display_name = "Gemini CLI",
    description = "Google Gemini via command line (requires Google account)",
    is_cli_model = true,
  },
  {
    name = "claude-cli",
    display_name = "Claude CLI",
    description = "Anthropic Claude via command line (requires Anthropic account)",
    is_cli_model = true,
  },
  {
    name = "codex-cli",
    display_name = "Codex CLI",
    description = "OpenAI Codex via command line (requires OpenAI account)",
    is_cli_model = true,
  },
}

---Get all model info (API + CLI)
---@return table[]
function M.get_all_model_info()
  local all = vim.deepcopy(M.MODEL_INFO)
  for _, cli_model in ipairs(M.CLI_MODEL_INFO) do
    table.insert(all, cli_model)
  end
  return all
end

---@class GeminiClient
---@field api_key string
---@field model string
---@field current_process table|nil  Current running process (for abort)
---@field is_aborted boolean
local GeminiClient = {}
GeminiClient.__index = GeminiClient

---Create a new Gemini client
---@param api_key string
---@param model? string
---@return GeminiClient
function M.new(api_key, model)
  local self = setmetatable({}, GeminiClient)
  self.api_key = api_key
  self.model = model or M.DEFAULT_MODEL
  self.current_process = nil
  self.is_aborted = false
  return self
end

---Abort current streaming request
---@param self GeminiClient
function GeminiClient:abort()
  self.is_aborted = true
  if self.current_process then
    self.current_process:kill(9)  -- SIGKILL
    self.current_process = nil
  end
end

---Check if client is currently streaming
---@param self GeminiClient
---@return boolean
function GeminiClient:is_streaming()
  return self.current_process ~= nil
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
  local web_search_enabled = opts.web_search_enabled
  local debug_mode = opts.debug_mode

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

  -- Web Search cannot be used with function calling tools
  if web_search_enabled then
    body.tools = { { google_search = vim.empty_dict() } }
  else
    -- Add tools
    if #tools > 0 then
      body.tools = { M.tools_to_declarations(tools) }
    end

    -- Add file_search tool if store names provided (for RAG via ragujuary)
    -- rag_store_name can be a string or array of strings
    if rag_store_name then
      local store_names = type(rag_store_name) == "table" and rag_store_name or { rag_store_name }
      if #store_names > 0 then
        body.tools = body.tools or {}
        table.insert(body.tools, {
          file_search = {
            file_search_store_names = store_names,
          }
        })
      end
    end
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
  local web_search_used = false
  local buffer = ""

  -- Reset abort flag
  self.is_aborted = false

  -- Debug: log request
  if debug_mode then
    vim.schedule(function()
      print("[DEBUG] URL: " .. url:gsub(self.api_key, "***"))
      print("[DEBUG] Web Search: " .. tostring(web_search_enabled))
      print("[DEBUG] Request body: " .. body_json:sub(1, 500))
    end)
  end

  -- Use vim.system for async curl with streaming stdout
  self.current_process = vim.system(
    {
      "curl", "-s", "-N", "-X", "POST", url,
      "-H", "Content-Type: application/json",
      "-d", "@" .. tmp_file,
      "--max-time", "120",
    },
    {
      text = true,
      stderr = function(err, data)
        if data and debug_mode then
          vim.schedule(function()
            print("[DEBUG] stderr: " .. data)
          end)
        end
      end,
      stdout = function(err, data)
        if err then return end
        if not data then return end

        if debug_mode then
          vim.schedule(function()
            print("[DEBUG] stdout received: " .. #data .. " bytes")
            print("[DEBUG] raw data: " .. data:sub(1, 500))
          end)
        end

        buffer = buffer .. data

        -- Process complete SSE lines
        while true do
          local line_end = buffer:find("\n")
          if not line_end then break end

          local line = buffer:sub(1, line_end - 1)
          buffer = buffer:sub(line_end + 1)

          if line:match("^data: ") then
            local data_str = line:sub(7)
            if debug_mode then
              vim.schedule(function()
                print("[DEBUG] SSE data: " .. data_str:sub(1, 200))
              end)
            end
            if data_str ~= "[DONE]" then
              local ok, parsed = pcall(json.decode, data_str)
              if not ok then
                if debug_mode then
                  vim.schedule(function()
                    print("[DEBUG] JSON parse error: " .. tostring(parsed))
                  end)
                end
              end
              if ok and parsed then
                -- Check for error in response first
                if parsed.error then
                  if on_error then
                    vim.schedule(function()
                      on_error("API error: " .. (parsed.error.message or json.encode(parsed.error)))
                    end)
                  end
                  return
                end
                if parsed.candidates and parsed.candidates[1] then
                  local candidate = parsed.candidates[1]
                  -- Check for blocked/filtered response
                  if candidate.finishReason and candidate.finishReason ~= "STOP" and candidate.finishReason ~= "MAX_TOKENS" then
                    if debug_mode then
                      vim.schedule(function()
                        print("[DEBUG] finishReason: " .. candidate.finishReason)
                      end)
                    end
                  end
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
                  if candidate.groundingMetadata then
                    if web_search_enabled then
                      -- Web Search was used
                      web_search_used = true
                      if on_chunk then
                        vim.schedule(function()
                          on_chunk({ type = "web_search_used" })
                        end)
                      end
                    elseif candidate.groundingMetadata.groundingChunks then
                      -- RAG/File Search was used
                      for _, gc in ipairs(candidate.groundingMetadata.groundingChunks) do
                        if gc.retrievedContext and gc.retrievedContext.uri then
                          table.insert(rag_sources, gc.retrievedContext.uri)
                        end
                      end
                    end
                  end
                else
                  -- No candidates in response - check for error message
                  if debug_mode then
                    vim.schedule(function()
                      print("[DEBUG] No candidates in response: " .. json.encode(parsed):sub(1, 500))
                    end)
                  end
                  -- Check if response contains an error we missed
                  if parsed.error then
                    if on_error then
                      vim.schedule(function()
                        on_error("API error: " .. (parsed.error.message or json.encode(parsed.error)))
                      end)
                    end
                    return
                  end
                end
              end
            end
          end
        end
      end,
    },
    function(result)
      -- Clean up temp file and process reference
      os.remove(tmp_file)
      self.current_process = nil

      vim.schedule(function()
        -- Debug: log completion
        if debug_mode then
          print("[DEBUG] curl completed. code=" .. tostring(result.code))
          if result.stderr and result.stderr ~= "" then
            print("[DEBUG] stderr: " .. result.stderr:sub(1, 200))
          end
          if result.stdout and result.stdout ~= "" then
            print("[DEBUG] stdout length: " .. #result.stdout)
          end
        end

        -- Check if aborted
        if self.is_aborted then
          if on_chunk then
            on_chunk({ type = "aborted" })
          end
          if on_done then
            on_done({
              text = accumulated_text,
              function_calls = {},
              rag_sources = {},
              web_search_used = false,
              aborted = true,
            })
          end
          return
        end

        if result.code ~= 0 then
          if on_error then
            local error_msg = "curl failed with code " .. result.code
            if result.code == 28 then
              error_msg = "Request timed out. If using RAG, check that the store name exists."
            elseif result.stderr and result.stderr ~= "" then
              error_msg = error_msg .. ": " .. result.stderr
            end
            on_error(error_msg)
          end
          return
        end

        -- Check if we got any content
        if accumulated_text == "" and #function_calls == 0 then
          -- No content received - might be an issue with the request
          if debug_mode then
            print("[DEBUG] No content received from API")
            print("[DEBUG] Remaining buffer: " .. buffer:sub(1, 500))
            if result.stdout then
              print("[DEBUG] Full stdout: " .. result.stdout:sub(1, 1000))
            end
          end

          -- Check remaining buffer for error
          if buffer ~= "" then
            local ok, parsed = pcall(json.decode, buffer)
            if ok and parsed and parsed.error then
              if on_error then
                on_error("API error: " .. (parsed.error.message or json.encode(parsed.error)))
              end
              return
            end
          end

          -- Check full stdout for error (non-SSE response)
          if result.stdout and result.stdout ~= "" then
            -- Try to find JSON error in stdout
            local ok, parsed = pcall(json.decode, result.stdout)
            if ok and parsed and parsed.error then
              if on_error then
                on_error("API error: " .. (parsed.error.message or json.encode(parsed.error)))
              end
              return
            end
          end
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
            web_search_used = web_search_used,
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
  local web_search_enabled = opts.web_search_enabled
  local max_iterations = opts.max_iterations or 10
  local debug_mode = opts.debug_mode

  local accumulated_text = ""
  local all_tool_calls = {}
  local all_tool_results = {}
  local web_search_was_used = false
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
      web_search_enabled = web_search_enabled,
      debug_mode = debug_mode,
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
        if result.web_search_used then
          web_search_was_used = true
        end

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
              web_search_used = web_search_was_used,
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

---List available file search stores (RAG stores)
---@param api_key string
---@param callback function(stores: table[]|nil, error: string|nil)
function M.list_file_search_stores(api_key, callback)
  local url = string.format("%s/fileSearchStores?key=%s", API_BASE, api_key)

  vim.system(
    { "curl", "-s", "-X", "GET", url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, "Failed to fetch stores: " .. (result.stderr or "unknown error"))
          return
        end

        local ok, parsed = pcall(json.decode, result.stdout or "")
        if not ok then
          callback(nil, "Failed to parse response")
          return
        end

        if parsed.error then
          callback(nil, "API error: " .. (parsed.error.message or json.encode(parsed.error)))
          return
        end

        -- Extract store names from response
        local stores = {}
        if parsed.fileSearchStores then
          for _, store in ipairs(parsed.fileSearchStores) do
            -- store.name is like "fileSearchStores/store-name"
            local name = store.name or ""
            local display_name = store.displayName or name:gsub("^fileSearchStores/", "")
            table.insert(stores, {
              name = name,
              display_name = display_name,
              description = store.description or "",
            })
          end
        end

        callback(stores, nil)
      end)
    end
  )
end

return M
