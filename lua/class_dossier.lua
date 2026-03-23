local M = {}

local get_main_class = require("get_main_class").get_main_class

M.config = {
  width = 64,
  side = "right", -- "right" | "left"
  timeout_ms = 700,
  max_hover_lines = 18,
  max_ref_files = 10,
  max_related_symbols = 12,
  max_methods = 18,
  max_fields = 18,
  notes_scope = "global", -- "project" | "global"
  notes_relpath = ".nvim/class-notes",
  notes_global_path = nil, -- defaults to ~/.nvim/class-notes
  prefer_client = "clangd",
}

local NS = vim.api.nvim_create_namespace("class_dossier")
local STATE = {}

local uv = vim.uv or vim.loop

local KIND = {
  File = 1,
  Module = 2,
  Namespace = 3,
  Package = 4,
  Class = 5,
  Method = 6,
  Property = 7,
  Field = 8,
  Constructor = 9,
  Enum = 10,
  Interface = 11,
  Function = 12,
  Variable = 13,
  Constant = 14,
  String = 15,
  Number = 16,
  Boolean = 17,
  Array = 18,
  Object = 19,
  Key = 20,
  Null = 21,
  EnumMember = 22,
  Struct = 23,
  Event = 24,
  Operator = 25,
  TypeParameter = 26,
}

local KIND_NAME = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

local function is_list(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
      return false
    end
    if k > n then
      n = k
    end
  end
  for i = 1, n do
    if rawget(t, i) == nil then
      return false
    end
  end
  return true
end

local function tbl_copy(list)
  local out = {}
  for i, v in ipairs(list or {}) do
    out[i] = v
  end
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function truncate(s, max_len)
  if not s then
    return ""
  end
  if #s <= max_len then
    return s
  end
  return s:sub(1, max_len - 1) .. "…"
end

local function short_path(path)
  if not path or path == "" then
    return ""
  end
  return vim.fn.fnamemodify(path, ":~:.")
end

local function joinpath(a, b)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then
    return a .. b
  end
  local sep = package.config:sub(1, 1)
  return a .. sep .. b
end

local function pos_in_range(row, col, range)
  if not range or not range.start or not range["end"] then
    return false
  end

  local s = range.start
  local e = range["end"]

  if row < s.line or row > e.line then
    return false
  end
  if row == s.line and col < s.character then
    return false
  end
  if row == e.line and col > e.character then
    return false
  end
  return true
end

local function range_span(range)
  if not range or not range.start or not range["end"] then
    return math.huge
  end
  return (range["end"].line - range.start.line) * 100000 + (range["end"].character - range.start.character)
end

local function is_classish(kind)
  return kind == KIND.Class or kind == KIND.Struct or kind == KIND.Interface
end

local function is_methodish(kind)
  return kind == KIND.Method
    or kind == KIND.Constructor
    or kind == KIND.Function
    or kind == KIND.Operator
end

local function is_fieldish(kind)
  return kind == KIND.Field
    or kind == KIND.Property
    or kind == KIND.Variable
    or kind == KIND.Constant
end

local function pick_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return nil
  end

  table.sort(clients, function(a, b)
    local function score(c)
      local s = 0
      if c.name == M.config.prefer_client then
        s = s + 100
      end
      if c:supports_method("textDocument/documentSymbol", bufnr) then
        s = s + 20
      end
      if c:supports_method("textDocument/hover", bufnr) then
        s = s + 10
      end
      if c:supports_method("textDocument/prepareTypeHierarchy", bufnr) then
        s = s + 8
      end
      if c:supports_method("workspace/symbol", bufnr) then
        s = s + 4
      end
      return s
    end
    return score(a) > score(b)
  end)

  return clients[1]
end

local function request_sync(client, bufnr, method, params, timeout_ms)
  if not client then
    return nil, "No active LSP client"
  end
  if not client:supports_method(method, bufnr) then
    return nil, ("Client does not support %s"):format(method)
  end

  local resp, err = client:request_sync(method, params, timeout_ms or M.config.timeout_ms, bufnr)
  if not resp then
    return nil, err or ("LSP request failed: " .. method)
  end
  if resp.err then
    return nil, resp.err.message or vim.inspect(resp.err)
  end
  return resp.result, nil
end

local function normalize_document_symbols(result)
  if type(result) ~= "table" or vim.tbl_isempty(result) then
    return {}, false
  end

  if result[1].location ~= nil then
    local flat = {}
    for _, sym in ipairs(result) do
      table.insert(flat, {
        name = sym.name,
        kind = sym.kind,
        detail = sym.detail,
        containerName = sym.containerName,
        range = sym.location.range,
        selectionRange = sym.location.range,
        children = {},
        _flat = true,
      })
    end
    return flat, true
  end

  return result, false
end

local function find_deepest_path(symbols, row, col, path)
  path = path or {}
  for _, sym in ipairs(symbols or {}) do
    local range = sym.range
    if range and pos_in_range(row, col, range) then
      local next_path = tbl_copy(path)
      next_path[#next_path + 1] = sym
      local child_path = find_deepest_path(sym.children or {}, row, col, next_path)
      return child_path or next_path
    end
  end
  return nil
end

local function find_smallest_containing_symbol(symbols, row, col)
  local best
  local best_span = math.huge
  for _, sym in ipairs(symbols or {}) do
    local range = sym.range
    if range and pos_in_range(row, col, range) then
      local span = range_span(range)
      if span < best_span then
        best = sym
        best_span = span
      end
    end
  end
  return best
end

local function find_enclosing_class(path)
  for i = #path, 1, -1 do
    if is_classish(path[i].kind) then
      return path[i], i
    end
  end
  return nil, nil
end

local function fq_name_from_path(path, upto)
  local parts = {}
  for i = 1, upto do
    local sym = path[i]
    if sym.kind == KIND.Namespace or is_classish(sym.kind) then
      parts[#parts + 1] = sym.name
    end
  end
  return table.concat(parts, "::")
end

local function symbol_uri(sym, fallback_uri)
  if sym.location and sym.location.uri then
    return sym.location.uri
  end
  if sym.uri then
    return sym.uri
  end
  return fallback_uri
end

local function symbol_range(sym)
  if sym.selectionRange then
    return sym.selectionRange
  end
  if sym.range then
    return sym.range
  end
  if sym.location and sym.location.range then
    return sym.location.range
  end
  return nil
end

local function symbol_position(sym)
  local range = symbol_range(sym)
  return range and range.start or nil
end

local function symbol_location(sym, fallback_uri)
  local uri = symbol_uri(sym, fallback_uri)
  local range = symbol_range(sym)
  if not uri or not range then
    return nil
  end
  return {
    uri = uri,
    range = range,
  }
end

local function symbol_fq_name(sym)
  if sym.containerName and sym.containerName ~= "" then
    return sym.containerName .. "::" .. sym.name
  end
  return sym.name
end

local function hierarchy_item_location(item)
  return {
    uri = item.uri,
    range = item.selectionRange or item.range,
  }
end

local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

local function homedir()
  if uv and uv.os_homedir then
    local ok, dir = pcall(uv.os_homedir)
    if ok and dir and dir ~= "" then
      return dir
    end
  end
  return vim.fn.expand("~")
end

local function resolve_global_notes_path()
  if M.config.notes_global_path and M.config.notes_global_path ~= "" then
    return vim.fn.expand(M.config.notes_global_path)
  end
  return joinpath(homedir(), ".nvim/class-notes")
end

local function resolve_notes_store(root_dir)
  local scope = M.config.notes_scope
  if scope == "global" then
    return {
      scope = "global",
      path = resolve_global_notes_path(),
    }
  end

  local rel = (M.config.notes_relpath or ".nvim/class-notes"):gsub("^[/\\]+", "")
  return {
    scope = "project",
    path = joinpath(root_dir, rel),
  }
end

local function sanitize_path_segment(s)
  if not s or s == "" then
    return "_"
  end
  s = s:gsub('[<>:"/\\|?*]', "_")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("[%.%s]+$", "")
  if s == "" then
    return "_"
  end
  return s
end

local function class_note_relpath(fq_name, class_name)
  local name = fq_name and fq_name ~= "" and fq_name or class_name
  local parts = {}
  for part in tostring(name):gmatch("[^:]+") do
    if part ~= "" then
      parts[#parts + 1] = sanitize_path_segment(part)
    end
  end

  if #parts == 0 then
    parts[1] = sanitize_path_segment(class_name or "UnknownClass")
  end

  local rel = parts[1]
  for i = 2, #parts do
    rel = joinpath(rel, parts[i])
  end
  return rel .. ".md"
end

local function class_note_path(store, fq_name, class_name)
  return joinpath(store.path, class_note_relpath(fq_name, class_name))
end

local function load_note(root_dir, fq_name, class_name, _file_path)
  local store = resolve_notes_store(root_dir)
  store.note_path = class_note_path(store, fq_name, class_name)

  local raw = read_file(store.note_path)
  if not raw then
    return nil, store
  end

  return raw, store
end

local function current_buffer_uri(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    return nil
  end
  return vim.uri_from_fname(name)
end

local function candidate_symbol_names(sym)
  local out = {}
  local seen = {}

  local function push(name)
    if type(name) ~= "string" then
      return
    end
    name = trim(name)
    if name == "" or seen[name] then
      return
    end
    seen[name] = true
    out[#out + 1] = name
  end

  push(sym and sym.name or nil)

  local tail = sym and sym.name and sym.name:match("([^:]+)$") or nil
  push(tail)

  if sym and sym.containerName and sym.name then
    push(sym.containerName .. "::" .. sym.name)
    local ctail = sym.containerName:match("([^:]+)$")
    if ctail and ctail ~= "" then
      push(ctail .. "::" .. sym.name)
    end
  end

  return out
end

local function find_symbol_position_in_buffer(bufnr, sym)
  local buf_uri = current_buffer_uri(bufnr)
  local sym_uri = symbol_uri(sym)
  local pos = symbol_position(sym)

  if pos and (not sym_uri or sym_uri == buf_uri) then
    return pos
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, name in ipairs(candidate_symbol_names(sym)) do
    for i, line in ipairs(lines) do
      local s = line:find(name, 1, true)
      if s then
        return {
          line = i - 1,
          character = s - 1,
        }
      end
    end
  end

  return nil
end

local function current_buffer_symbol_params(bufnr, sym, fallback_uri)
  local uri = current_buffer_uri(bufnr) or fallback_uri or symbol_uri(sym, fallback_uri)
  local position = find_symbol_position_in_buffer(bufnr, sym)
  if not uri or not position then
    return nil
  end

  return {
    textDocument = { uri = uri },
    position = position,
  }
end

local function hover_lines(client, bufnr, sym, fallback_uri)
  local params = current_buffer_symbol_params(bufnr, sym, fallback_uri)
  if not params then
    return {}
  end

  local result = request_sync(client, bufnr, "textDocument/hover", params)
  if not result or not result.contents then
    return {}
  end

  local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
  while #lines > 0 and trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and trim(lines[#lines]) == "" do
    table.remove(lines, #lines)
  end
  if #lines > M.config.max_hover_lines then
    lines = vim.list_slice(lines, 1, M.config.max_hover_lines)
    lines[#lines + 1] = "…"
  end
  return lines
end

local function prepare_type_hierarchy(client, bufnr, sym, fallback_uri)
  local params = current_buffer_symbol_params(bufnr, sym, fallback_uri)
  if not params then
    return nil
  end

  local items = request_sync(client, bufnr, "textDocument/prepareTypeHierarchy", params)
  if type(items) ~= "table" or vim.tbl_isempty(items) then
    return nil
  end

  for _, item in ipairs(items) do
    if item.name == sym.name then
      return item
    end
  end
  return items[1]
end

local function get_hierarchy(client, bufnr, sym, fallback_uri)
  local item = prepare_type_hierarchy(client, bufnr, sym, fallback_uri)
  if not item then
    return {}, {}
  end

  local supers = request_sync(client, bufnr, "typeHierarchy/supertypes", { item = item }) or {}
  local subs = request_sync(client, bufnr, "typeHierarchy/subtypes", { item = item }) or {}
  return supers, subs
end

local function get_references(client, bufnr, sym, fallback_uri)
  local params = current_buffer_symbol_params(bufnr, sym, fallback_uri)
  if not params then
    return {}, {}
  end

  params.context = { includeDeclaration = false }

  local refs = request_sync(client, bufnr, "textDocument/references", params, M.config.timeout_ms * 2) or {}
  local by_file = {}

  for _, loc in ipairs(refs) do
    if loc.uri then
      local fname = vim.uri_to_fname(loc.uri)
      local bucket = by_file[fname]
      if not bucket then
        bucket = { file = fname, count = 0, first = loc }
        by_file[fname] = bucket
      end
      bucket.count = bucket.count + 1
    end
  end

  local grouped = {}
  for _, bucket in pairs(by_file) do
    grouped[#grouped + 1] = bucket
  end

  table.sort(grouped, function(a, b)
    if a.count == b.count then
      return a.file < b.file
    end
    return a.count > b.count
  end)

  return refs, grouped
end

local walk_symbol_tree

local function get_document_symbols_for_uri(client, bufnr, uri)
  if not uri then
    return {}, false
  end

  local result = request_sync(
    client,
    bufnr,
    "textDocument/documentSymbol",
    {
      textDocument = { uri = uri },
    },
    M.config.timeout_ms * 2
  )

  if type(result) ~= "table" or vim.tbl_isempty(result) then
    return {}, false
  end

  return normalize_document_symbols(result)
end

local function starts_with(s, prefix)
  return type(s) == "string" and type(prefix) == "string" and prefix ~= "" and s:sub(1, #prefix) == prefix
end

local function ends_with(s, suffix)
  return type(s) == "string" and type(suffix) == "string" and suffix ~= "" and s:sub(-#suffix) == suffix
end

local function symbol_matches_class(sym, candidate_fq, fq_name, class_name)
  local name = trim(sym and sym.name or "")
  local container = trim(sym and sym.containerName or "")

  if name == "" then
    return false
  end

  if candidate_fq ~= "" and (candidate_fq == fq_name or starts_with(candidate_fq, fq_name .. "::")) then
    return true
  end

  if fq_name ~= "" then
    if name == fq_name or starts_with(name, fq_name .. "::") then
      return true
    end
    if container == fq_name or starts_with(container, fq_name .. "::") or ends_with(container, "::" .. fq_name) then
      return true
    end
  end

  if class_name ~= "" then
    if name == class_name or starts_with(name, class_name .. "::") then
      return true
    end
    if container == class_name or starts_with(container, class_name .. "::") or ends_with(container, "::" .. class_name) then
      return true
    end
  end

  return false
end

local function current_buffer_method_defs(client, bufnr, fq_name, class_name)
  local uri = current_buffer_uri(bufnr)
  local symbols = get_document_symbols_for_uri(client, bufnr, uri)
  if type(symbols) ~= "table" or vim.tbl_isempty(symbols) then
    return {}
  end

  local walked = walk_symbol_tree(symbols)
  local methods = {}
  local seen = {}

  for _, entry in ipairs(walked) do
    local sym = entry.sym
    if is_methodish(sym.kind) then
      local candidate_fq = trim(entry.fq_name or "")
      if symbol_matches_class(sym, candidate_fq, fq_name, class_name) then
        local loc = symbol_location(sym, uri)
        local key = table.concat({
          sym.name or "",
          loc and loc.uri or uri or "",
          loc and loc.range and loc.range.start and loc.range.start.line or "",
          loc and loc.range and loc.range.start and loc.range.start.character or "",
        }, "|")

        if not seen[key] then
          seen[key] = true
          methods[#methods + 1] = sym
        end
      end
    end
  end

  return methods
end

local function choose_call_hierarchy_item(items, sym)
  if type(items) ~= "table" or vim.tbl_isempty(items) then
    return nil
  end

  local wanted_name = sym and sym.name or nil
  local wanted_pos = symbol_position(sym)

  for _, item in ipairs(items) do
    local item_range = item.selectionRange or item.range
    if wanted_name and item.name == wanted_name and wanted_pos and item_range and item_range.start then
      if item_range.start.line == wanted_pos.line then
        return item
      end
    end
  end

  for _, item in ipairs(items) do
    if wanted_name and item.name == wanted_name then
      return item
    end
  end

  return items[1]
end

local function get_outgoing_hotspots(client, bufnr, fq_name, class_name)
  if not client:supports_method("textDocument/prepareCallHierarchy", bufnr) then
    return {}, 0
  end
  if not client:supports_method("callHierarchy/outgoingCalls", bufnr) then
    return {}, 0
  end

  local methods = current_buffer_method_defs(client, bufnr, fq_name, class_name)
  if #methods == 0 then
    return {}, 0
  end

  local current_uri = current_buffer_uri(bufnr)
  local by_file = {}
  local seen_items = {}
  local total = 0

  for _, method in ipairs(methods) do
    local params = current_buffer_symbol_params(bufnr, method, current_uri)
    if params then
      local items = request_sync(client, bufnr, "textDocument/prepareCallHierarchy", params, M.config.timeout_ms * 2) or {}
      local item = choose_call_hierarchy_item(items, method)
      if item then
        local item_loc = hierarchy_item_location(item)
        local item_key = table.concat({
          item.name or "",
          item.uri or "",
          item_loc and item_loc.range and item_loc.range.start and item_loc.range.start.line or "",
          item_loc and item_loc.range and item_loc.range.start and item_loc.range.start.character or "",
        }, "|")

        if not seen_items[item_key] then
          seen_items[item_key] = true

          local calls = request_sync(
            client,
            bufnr,
            "callHierarchy/outgoingCalls",
            { item = item },
            M.config.timeout_ms * 2
          ) or {}

          for _, call in ipairs(calls) do
            local target = call.to or call.item
            if target and target.uri then
              local fname = vim.uri_to_fname(target.uri)
              local count = 1
              if type(call.fromRanges) == "table" and #call.fromRanges > 0 then
                count = #call.fromRanges
              end

              local bucket = by_file[fname]
              if not bucket then
                bucket = {
                  file = fname,
                  count = 0,
                  first = hierarchy_item_location(target),
                }
                by_file[fname] = bucket
              end

              bucket.count = bucket.count + count
              total = total + count
            end
          end
        end
      end
    end
  end

  local grouped = {}
  for _, bucket in pairs(by_file) do
    grouped[#grouped + 1] = bucket
  end

  table.sort(grouped, function(a, b)
    if a.count == b.count then
      return a.file < b.file
    end
    return a.count > b.count
  end)

  return grouped, total
end

local function get_workspace_symbols(client, bufnr, query, fq_name, current_file)
  local result = request_sync(client, bufnr, "workspace/symbol", { query = query }, M.config.timeout_ms * 2)
  if type(result) ~= "table" then
    return {}
  end

  local out = {}
  for _, sym in ipairs(result) do
    local uri = symbol_uri(sym)
    if uri then
      local file = vim.uri_to_fname(uri)
      local score = 0
      if sym.name == query then
        score = score + 10
      end
      if sym.name == fq_name then
        score = score + 6
      end
      if symbol_fq_name(sym) == fq_name then
        score = score + 6
      end
      if is_classish(sym.kind) then
        score = score + 4
      end
      if sym.containerName and fq_name:find(sym.containerName, 1, true) then
        score = score + 3
      end
      if file ~= current_file then
        score = score + 1
      end

      out[#out + 1] = {
        score = score,
        symbol = sym,
      }
    end
  end

  table.sort(out, function(a, b)
    if a.score == b.score then
      if a.symbol.name == b.symbol.name then
        local af = symbol_uri(a.symbol) or ""
        local bf = symbol_uri(b.symbol) or ""
        return af < bf
      end
      return a.symbol.name < b.symbol.name
    end
    return a.score > b.score
  end)

  local dedup = {}
  local filtered = {}
  for _, item in ipairs(out) do
    local sym = item.symbol
    local range = symbol_range(sym)
    local key = table.concat({
      sym.name or "",
      tostring(sym.kind or ""),
      sym.containerName or "",
      symbol_uri(sym) or "",
      range and range.start and range.start.line or "",
    }, "|")

    if not dedup[key] then
      dedup[key] = true
      filtered[#filtered + 1] = sym
      if #filtered >= M.config.max_related_symbols then
        break
      end
    end
  end

  return filtered
end

local function sort_children_by_pos(children)
  table.sort(children, function(a, b)
    local ar = a.selectionRange or a.range
    local br = b.selectionRange or b.range
    if not ar or not br then
      return (a.name or "") < (b.name or "")
    end
    if ar.start.line == br.start.line then
      return ar.start.character < br.start.character
    end
    return ar.start.line < br.start.line
  end)
end

local function class_members(class_sym)
  local fields, methods = {}, {}
  for _, child in ipairs(class_sym.children or {}) do
    if is_fieldish(child.kind) then
      fields[#fields + 1] = child
    elseif is_methodish(child.kind) then
      methods[#methods + 1] = child
    end
  end

  sort_children_by_pos(fields)
  sort_children_by_pos(methods)

  if #fields > M.config.max_fields then
    fields = vim.list_slice(fields, 1, M.config.max_fields)
  end
  if #methods > M.config.max_methods then
    methods = vim.list_slice(methods, 1, M.config.max_methods)
  end

  return fields, methods
end

local function format_note_lines(note, store)
  local lines = {}

  if note == nil then
    lines[#lines + 1] = "_No personal note found._"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "- **Scope:** " .. store.scope
    lines[#lines + 1] = "- **Store dir:** `" .. short_path(store.path) .. "`"
    lines[#lines + 1] = "- **Note file:** `" .. short_path(store.note_path) .. "`"
    return lines
  end

  lines[#lines + 1] = "- **Scope:** " .. store.scope
  lines[#lines + 1] = "- **Store dir:** `" .. short_path(store.path) .. "`"
  lines[#lines + 1] = "- **Note file:** `" .. short_path(store.note_path) .. "`"
  lines[#lines + 1] = ""

  if type(note) ~= "string" then
    note = tostring(note)
  end

  local body = note:gsub("\r\n", "\n"):gsub("\r", "\n")

  if body:match("^%s*#%s+") then
    body = body:gsub("^%s*#%s+[^\n]*\n?", "", 1)
  end

  local parts = vim.split(body, "\n", { plain = true, trimempty = false })
  for _, part in ipairs(parts) do
    lines[#lines + 1] = part
  end

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end

  return lines
end


walk_symbol_tree = function(symbols, path, out)
  path = path or {}
  out = out or {}

  for _, sym in ipairs(symbols or {}) do
    local next_path = tbl_copy(path)
    next_path[#next_path + 1] = sym

    out[#out + 1] = {
      sym = sym,
      path = next_path,
      fq_name = fq_name_from_path(next_path, #next_path),
    }

    walk_symbol_tree(sym.children or {}, next_path, out)
  end

  return out
end

local function find_main_class_in_document_symbols(symbols, is_flat, main_class, fallback_uri)
  local identifier = trim(main_class.identifier or "")
  local full_qualified = trim(main_class.full_qualified or "")
  local namespace = trim(main_class.namespace or "")

  local best_sym, best_path, best_fq
  local best_score = -1

  local function consider(sym, path, container_name, candidate_fq)
    if not is_classish(sym.kind) then
      return
    end

    local score = 0

    if sym.name == identifier then
      score = score + 50
    end
    if full_qualified ~= "" and candidate_fq == full_qualified then
      score = score + 100
    end
    if full_qualified ~= "" and sym.name == full_qualified then
      score = score + 80
    end
    if namespace ~= "" and container_name == namespace then
      score = score + 30
    end

    if score > best_score then
      best_score = score
      best_sym = sym
      best_path = path
      best_fq = candidate_fq
    end
  end

  if is_flat then
    for _, sym in ipairs(symbols or {}) do
      local container_name = trim(sym.containerName or "")
      local candidate_fq = container_name ~= "" and (container_name .. "::" .. sym.name) or sym.name
      consider(sym, { sym }, container_name, candidate_fq)
    end
  else
    for _, entry in ipairs(walk_symbol_tree(symbols)) do
      local container_name = fq_name_from_path(entry.path, #entry.path - 1)
      consider(entry.sym, entry.path, container_name, entry.fq_name)
    end
  end

  if best_sym and not best_sym.location then
    best_sym.location = symbol_location(best_sym, fallback_uri)
  end

  return best_sym, best_path, best_fq
end

local function make_context_from_class_symbol(class_sym, path, class_index, fq_name, uri, current_file)
  local fields, methods = class_members(class_sym)
  return {
    class_symbol = class_sym,
    workspace_symbol = class_sym,
    path = path,
    class_index = class_index,
    fq_name = fq_name ~= "" and fq_name or trim(class_sym.name or ""),
    class_name = trim(class_sym.name or ""),
    symbol_uri = uri,
    file = uri and vim.uri_to_fname(uri) or current_file,
    fields = fields,
    methods = methods,
  }
end

local function class_hint_from_symbol(sym)
  if not sym then
    return nil
  end

  local name = trim(sym.name or "")
  local container = trim(sym.containerName or "")

  if is_classish(sym.kind) then
    return {
      identifier = name,
      full_qualified = container ~= "" and (container .. "::" .. name) or name,
      namespace = container,
    }
  end

  local owner_fq = ""
  if container ~= "" then
    owner_fq = container
  elseif name:find("::", 1, true) then
    owner_fq = trim(name:match("^(.*)::[^:]+$") or "")
  end

  if owner_fq == "" then
    return nil
  end

  local identifier = owner_fq:match("([^:]+)$") or owner_fq
  local namespace = trim(owner_fq:match("^(.*)::[^:]+$") or "")

  return {
    identifier = trim(identifier or ""),
    full_qualified = owner_fq,
    namespace = namespace,
  }
end

local resolve_main_class_workspace_symbol

local function resolve_context_for_class_hint(client, bufnr, main_class, current_file)
  local ws_sym, ws_err = resolve_main_class_workspace_symbol(client, bufnr, main_class, current_file)
  if not ws_sym then
    return nil, ws_err
  end

  local decl_uri = symbol_uri(ws_sym)
  local fq_name = trim(main_class.full_qualified or "")
  if fq_name == "" then
    fq_name = symbol_fq_name(ws_sym)
  end

  local class_sym = ws_sym
  local fields, methods = {}, {}
  local path, class_index = nil, nil

  if decl_uri then
    local doc_result = request_sync(
      client,
      bufnr,
      "textDocument/documentSymbol",
      {
        textDocument = { uri = decl_uri },
      },
      M.config.timeout_ms * 2
    )

    if type(doc_result) == "table" and not vim.tbl_isempty(doc_result) then
      local symbols, is_flat = normalize_document_symbols(doc_result)
      if not vim.tbl_isempty(symbols) then
        local decl_sym, decl_path, resolved_fq =
          find_main_class_in_document_symbols(symbols, is_flat, main_class, decl_uri)

        if decl_sym then
          class_sym = decl_sym
          path = decl_path
          class_index = decl_path and #decl_path or 1
          fq_name = resolved_fq or fq_name
          fields, methods = class_members(decl_sym)
        end
      end
    end
  end

  return {
    class_symbol = class_sym,
    workspace_symbol = ws_sym,
    path = path,
    class_index = class_index,
    fq_name = fq_name,
    class_name = trim(main_class.identifier or class_sym.name or ""),
    symbol_uri = decl_uri,
    file = decl_uri and vim.uri_to_fname(decl_uri) or current_file,
    fields = fields,
    methods = methods,
  }, nil
end

local function build_context_from_cursor(client, bufnr, current_file)
  local uri = current_buffer_uri(bufnr)
  local symbols, is_flat = get_document_symbols_for_uri(client, bufnr, uri)
  if type(symbols) ~= "table" or vim.tbl_isempty(symbols) then
    return nil, "Cursor fallback could not read document symbols"
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  if not is_flat then
    local path = find_deepest_path(symbols, row, col)
    if path and #path > 0 then
      local class_sym, class_index = find_enclosing_class(path)
      if class_sym and class_index then
        if not class_sym.location then
          class_sym.location = symbol_location(class_sym, uri)
        end
        local fq_name = fq_name_from_path(path, class_index)
        return make_context_from_class_symbol(class_sym, path, class_index, fq_name, uri, current_file), nil
      end

      local hint = class_hint_from_symbol(path[#path])
      if hint and trim(hint.identifier or "") ~= "" then
        local ctx, err = resolve_context_for_class_hint(client, bufnr, hint, current_file)
        if ctx then
          return ctx, nil
        end
        return nil, err
      end
    end
  end

  local sym = find_smallest_containing_symbol(symbols, row, col)
  if sym and is_classish(sym.kind) then
    if not sym.location then
      sym.location = symbol_location(sym, uri)
    end
    local fq_name = trim(symbol_fq_name(sym))
    return make_context_from_class_symbol(sym, { sym }, 1, fq_name, uri, current_file), nil
  end

  local hint = class_hint_from_symbol(sym)
  if hint and trim(hint.identifier or "") ~= "" then
    return resolve_context_for_class_hint(client, bufnr, hint, current_file)
  end

  local cword = trim(vim.fn.expand("<cword>"))
  if cword ~= "" then
    local query = cword
    local fq = cword
    if cword:find("::", 1, true) then
      query = cword:match("([^:]+)$") or cword
    end
    local namespace = trim((fq:match("^(.*)::[^:]+$")) or "")
    return resolve_context_for_class_hint(client, bufnr, {
      identifier = query,
      full_qualified = fq,
      namespace = namespace,
    }, current_file)
  end

  return nil, "Cursor fallback could not infer a class from the current symbol"
end

resolve_main_class_workspace_symbol = function(client, bufnr, main_class, current_file)
  local query = trim(main_class.identifier or "")
  local full_qualified = trim(main_class.full_qualified or "")
  local namespace = trim(main_class.namespace or "")

  if query == "" then
    return nil, "get_main_class() returned an empty identifier"
  end

  local resp, req_err = client:request_sync(
    "workspace/symbol",
    { query = query },
    M.config.timeout_ms * 2,
    bufnr
  )

  if not resp then
    return nil, req_err or ("workspace/symbol failed for %q"):format(query)
  end

  if resp.err then
    return nil, ("workspace/symbol returned LSP error for %q: %s"):format(
      query,
      resp.err.message or tostring(resp.err)
    )
  end

  local result = resp.result
  if type(result) ~= "table" or vim.tbl_isempty(result) then
    return nil, ("No workspace symbols found for %q"):format(query)
  end

  local best_sym = nil
  local best_score = -1

  local normalized_current = current_file and vim.fs.normalize(current_file) or nil

  for _, sym in ipairs(result) do
    local uri = symbol_uri(sym)
    if uri then
      local file = vim.fs.normalize(vim.uri_to_fname(uri))
      local candidate_fq = symbol_fq_name(sym)
      local score = 0

      if is_classish(sym.kind) then
        score = score + 40
      end

      if sym.name == query then
        score = score + 50
      end

      if full_qualified ~= "" and candidate_fq == full_qualified then
        score = score + 100
      end

      -- Heuristic only. containerName is not authoritative.
      if namespace ~= "" and sym.containerName == namespace then
        score = score + 20
      end

      -- Prefer declaration/header over the current cpp file.
      if normalized_current and file ~= normalized_current then
        score = score + 5
      end

      if score > best_score then
        best_score = score
        best_sym = sym
      end
    end
  end

  if not best_sym then
    local wanted = full_qualified ~= "" and full_qualified or query
    return nil, ("Main class %q was not found in workspace symbols"):format(wanted)
  end

  return best_sym, nil
end

local function resolve_main_class_workspace_symbol_old(client, bufnr, main_class, current_file)
  local query = trim(main_class.identifier or "")
  local full_qualified = trim(main_class.full_qualified or "")
  local namespace = trim(main_class.namespace or "")

  if query == "" then
    return nil, "get_main_class() returned an empty identifier"
  end

  local result = request_sync(client, bufnr, "workspace/symbol", { query = query }, M.config.timeout_ms * 2)
  if type(result) ~= "table" or vim.tbl_isempty(result) then
    return nil, ("No workspace symbols found for %q"):format(query)
  end

  local best_sym = nil
  local best_score = -1

  for _, sym in ipairs(result) do
    local uri = symbol_uri(sym)
    if uri then
      local file = vim.uri_to_fname(uri)
      local candidate_fq = symbol_fq_name(sym)
      local score = 0

      if is_classish(sym.kind) then
        score = score + 40
      end
      if sym.name == query then
        score = score + 50
      end
      if full_qualified ~= "" and candidate_fq == full_qualified then
        score = score + 100
      end
      if full_qualified ~= "" and sym.name == full_qualified then
        score = score + 80
      end
      if namespace ~= "" and sym.containerName == namespace then
        score = score + 30
      end
      if file ~= current_file then
        score = score + 5
      end

      if score > best_score then
        best_score = score
        best_sym = sym
      end
    end
  end

  if not best_sym then
    local wanted = full_qualified ~= "" and full_qualified or query
    return nil, ("Main class %q was not found in workspace symbols"):format(wanted)
  end

  return best_sym, nil
end

local function build_context(client, bufnr)
  local current_file = vim.api.nvim_buf_get_name(bufnr)

  local main_class, main_err = get_main_class()
  if main_class and trim(main_class.identifier or "") ~= "" then
    local ctx, ctx_err = resolve_context_for_class_hint(client, bufnr, main_class, current_file)
    if ctx then
      return ctx
    end
    main_err = ctx_err or main_err
  elseif not main_err or main_err == "" then
    main_err = "get_main_class() did not return a class for this file"
  end

  local cursor_ctx, cursor_err = build_context_from_cursor(client, bufnr, current_file)
  if cursor_ctx then
    return cursor_ctx
  end

  return nil, cursor_err or main_err or "Could not resolve a class from the file or cursor symbol"
end

local function ensure_parent_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
end

local function file_exists(path)
  local st = uv and uv.fs_stat and uv.fs_stat(path) or nil
  return st ~= nil
end

local function write_file(path, content)
  ensure_parent_dir(path)
  local fd, err = io.open(path, "wb")
  if not fd then
    return false, err
  end
  fd:write(content)
  fd:close()
  return true, nil
end

local function note_template(fq_name)
  return table.concat({
    "# " .. fq_name,
    "",
    "## Role",
    "",
    "",
    "## Memo",
    "",
    "",
    "## Neighbors",
    "",
    "- ",
    "",
    "## Created by",
    "",
    "",
    "## Owns",
    "",
    "- ",
    "",
    "## Does not own",
    "",
    "- ",
    "",
    "## Hot methods",
    "",
    "- ",
    "",
    "## Hazards",
    "",
    "- ",
    "",
    "## Analogy",
    "",
    "",
  }, " ")
end

local function find_existing_dossier()
  for buf, _ in pairs(STATE) do
    if vim.api.nvim_buf_is_valid(buf) then
      local ok, name = pcall(vim.api.nvim_buf_get_name, buf)
      if ok and type(name) == "string" and vim.startswith(name, "ClassDossier://") then
        local wins = vim.fn.win_findbuf(buf)
        for _, win in ipairs(wins) do
          if vim.api.nvim_win_is_valid(win) then
            return buf, win
          end
        end
        return buf, nil
      end
    else
      STATE[buf] = nil
    end
  end
  return nil, nil
end

local function configure_dossier_buffer(buf)
  vim.bo[buf].buftype = "nofile"
  --vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  --vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "markdown"
end

local function configure_dossier_window(win)
  vim.api.nvim_win_set_width(win, M.config.width)
  vim.wo[win].number = true
  vim.wo[win].relativenumber = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true
  vim.wo[win].spell = false
end

local function open_dossier_window(name)
  local buf, win = find_existing_dossier()

  if not buf then
    if M.config.side == "left" then
      vim.cmd("topleft vsplit")
    else
      vim.cmd("botright vsplit")
    end

    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
  elseif win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  else
    if M.config.side == "left" then
      vim.cmd("topleft vsplit")
    else
      vim.cmd("botright vsplit")
    end

    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end

  configure_dossier_buffer(buf)
  configure_dossier_window(win)

  pcall(vim.api.nvim_buf_set_name, buf, "ClassDossier://" .. name)
  return buf, win
end

local function add_highlights(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, line in ipairs(lines) do
    if line:match("^# ") then
      vim.api.nvim_buf_add_highlight(buf, NS, "Title", i - 1, 0, -1)
    elseif line:match("^## ") then
      vim.api.nvim_buf_add_highlight(buf, NS, "Special", i - 1, 0, -1)
    elseif line:match("^%- ") then
      vim.api.nvim_buf_add_highlight(buf, NS, "Identifier", i - 1, 0, 1)
    end
  end
end

local function current_action()
  local buf = vim.api.nvim_get_current_buf()
  local st = STATE[buf]
  if not st then
    return nil, nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return st.actions[lnum], st
end

local function with_source_window(st, fn)
  local dossier_win = vim.api.nvim_get_current_win()
  local source_win = st and st.source_win or nil

  if source_win and vim.api.nvim_win_is_valid(source_win) and source_win ~= dossier_win then
    vim.api.nvim_set_current_win(source_win)
    return fn(source_win)
  end

  vim.cmd("rightbelow split")
  return fn(vim.api.nvim_get_current_win())
end

local function action_jump(preview)
  local action, st = current_action()
  if not action or not action.location then
    return
  end

  local client = action.client_id and vim.lsp.get_client_by_id(action.client_id) or nil
  if preview then
    vim.lsp.util.preview_location(action.location, { border = "rounded", focusable = true })
  else
    with_source_window(st, function()
      vim.lsp.util.show_document(
        action.location,
        client and client.offset_encoding or "utf-16",
        { reuse_win = false, focus = true }
      )
    end)
  end
end

local function action_run(kind)
  local action, st = current_action()
  if not action or not action.location then
    return
  end

  if (kind == "incoming" or kind == "outgoing") and not action.callable then
    vim.notify("Incoming/outgoing calls only make sense on a method/function line.", vim.log.levels.INFO)
    return
  end

  local client = action.client_id and vim.lsp.get_client_by_id(action.client_id) or nil
  if not client then
    vim.notify("LSP client is no longer available.", vim.log.levels.WARN)
    return
  end

  with_source_window(st, function()
    local ok = vim.lsp.util.show_document(
      action.location,
      client.offset_encoding or "utf-16",
      { reuse_win = false, focus = true }
    )
    if not ok then
      return
    end

    if kind == "hover" then
      vim.lsp.buf.hover()
    elseif kind == "refs" then
      vim.lsp.buf.references()
    elseif kind == "incoming" then
      vim.lsp.buf.incoming_calls()
    elseif kind == "outgoing" then
      vim.lsp.buf.outgoing_calls()
    end
  end)
end

local function install_buffer_maps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("n", "q", function()
    vim.cmd("close")
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    action_jump(false)
  end, opts)

  vim.keymap.set("n", "p", function()
    action_jump(true)
  end, opts)

  vim.keymap.set("n", "K", function()
    action_run("hover")
  end, opts)

  vim.keymap.set("n", "r", function()
    action_run("refs")
  end, opts)

  vim.keymap.set("n", "i", function()
    action_run("incoming")
  end, opts)

  vim.keymap.set("n", "o", function()
    action_run("outgoing")
  end, opts)
end

local function render(buf, win, data)
  local lines = {}
  local actions = {}

  local function add(line, action)
    lines[#lines + 1] = line
    actions[#lines] = action
  end

  local function add_blank()
    lines[#lines + 1] = ""
    actions[#lines] = nil
  end

  local function add_location_bullet(label, location, client_id, callable)
    add("- " .. label, {
      location = location,
      client_id = client_id,
      callable = callable or false,
    })
  end

  local file_path = short_path(data.file)
  local class_loc = symbol_location(data.class_symbol, data.symbol_uri)
  local root_path = short_path(data.root_dir)

  add("# Class Dossier: " .. data.fq_name)
  add("_Use `<CR>` jump, `p` preview, `K` hover, `r` refs, `i/o` incoming/outgoing calls on method lines._")
  add_blank()

  add("## Identity")
  add("- **Kind:** " .. (KIND_NAME[data.class_symbol.kind] or tostring(data.class_symbol.kind)))
  add_location_bullet("**File:** " .. file_path, class_loc, data.client_id, false)
  add("- **Project root:** " .. root_path)
  add("- **LSP client:** " .. data.client_name)
  add_blank()

  add("## Personal notes")
  for _, line in ipairs(data.note_lines) do
    add(line)
  end

  add_blank()

  add("## Summary")
  if #data.hover > 0 then
    for _, line in ipairs(data.hover) do
      add(line)
    end
  else
    add("_No hover documentation available for this class._")
  end
  add_blank()

  add("## Hierarchy")
  if #data.supers == 0 then
    add("- **Bases:** none")
  else
    add("- **Bases:**")
    for _, item in ipairs(data.supers) do
      local detail = item.detail and (" — " .. truncate(item.detail, 48)) or ""
      add_location_bullet(
        "  - " .. item.name .. detail,
        hierarchy_item_location(item),
        data.client_id,
        false
      )
    end
  end

  if #data.subs == 0 then
    add("- **Derived:** none")
  else
    add("- **Derived:**")
    for _, item in ipairs(data.subs) do
      local detail = item.detail and (" — " .. truncate(item.detail, 48)) or ""
      add_location_bullet(
        "  - " .. item.name .. detail,
        hierarchy_item_location(item),
        data.client_id,
        false
      )
    end
  end
  add_blank()

  add("## Neighborhood")
  add(("- **References:** %d total"):format(#data.refs))

  if #data.ref_files == 0 then
    add("- **Reference hotspots:** none")
  else
    add("- **Reference hotspots by file:**")
    for i, bucket in ipairs(data.ref_files) do
      if i > M.config.max_ref_files then
        break
      end
      add_location_bullet(
        ("  - %s (%d)"):format(short_path(bucket.file), bucket.count),
        bucket.first,
        data.client_id,
        false
      )
    end
  end

  add(("- **Outgoing calls:** %d total call sites"):format(data.outgoing_total or 0))

  if not data.outgoing_files or #data.outgoing_files == 0 then
    add("- **Outgoing call hotspots:** none")
  else
    add("- **Outgoing call hotspots by file:**")
    for i, bucket in ipairs(data.outgoing_files) do
      if i > M.config.max_ref_files then
        break
      end
      add_location_bullet(
        ("  - %s (%d)"):format(short_path(bucket.file), bucket.count),
        bucket.first,
        data.client_id,
        false
      )
    end
  end

  if #data.related == 0 then
    add("- **Related symbols:** none")
  else
    add("- **Related workspace symbols:**")
    for _, sym in ipairs(data.related) do
      local container = sym.containerName and (" — " .. sym.containerName) or ""
      local path = sym.location and short_path(vim.uri_to_fname(sym.location.uri)) or ""
      add_location_bullet(
        ("  - %s [%s]%s (%s)"):format(
          sym.name,
          KIND_NAME[sym.kind] or tostring(sym.kind),
          container,
          path
        ),
        sym.location,
        data.client_id,
        false
      )
    end
  end
  add_blank()

  add("## Members")
  if #data.fields == 0 then
    add("- **Fields:** none surfaced by document symbols")
  else
    add("- **Fields:**")
    for _, field in ipairs(data.fields) do
      add_location_bullet(
        "  - " .. field.name .. " [" .. (KIND_NAME[field.kind] or tostring(field.kind)) .. "]",
        symbol_location(field, data.symbol_uri),
        data.client_id,
        false
      )
    end
  end

  if #data.methods == 0 then
    add("- **Methods:** none surfaced by document symbols")
  else
    add("- **Methods:**")
    for _, method in ipairs(data.methods) do
      add_location_bullet(
        "  - " .. method.name .. " [" .. (KIND_NAME[method.kind] or tostring(method.kind)) .. "]",
        symbol_location(method, data.symbol_uri),
        data.client_id,
        true
      )
    end
  end
  add_blank()

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  add_highlights(buf, lines)
  install_buffer_maps(buf)

  STATE[buf] = {
    actions = actions,
    data = data,
    source_win = data.source_win,
  }

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

function M.set_notes_scope(scope)
  if scope ~= "project" and scope ~= "global" then
    vim.notify("ClassDossier notes scope must be 'project' or 'global'.", vim.log.levels.ERROR)
    return false
  end

  M.config.notes_scope = scope
  vim.notify("ClassDossier notes scope set to " .. scope, vim.log.levels.INFO)
  return true
end

function M.edit_note()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = pick_client(bufnr)
  if not client then
    vim.notify("No LSP client attached to current buffer.", vim.log.levels.ERROR)
    return
  end

  local ctx, err = build_context(client, bufnr)
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local root_dir = client.config.root_dir or vim.fn.getcwd()
  local store = resolve_notes_store(root_dir)
  local note_path = class_note_path(store, ctx.fq_name, ctx.class_name ~= "" and ctx.class_name or ctx.class_symbol.name)

  if not file_exists(note_path) then
    local ok, write_err = write_file(note_path, note_template(ctx.fq_name))
    if not ok then
      vim.notify("Failed to create note file: " .. tostring(write_err), vim.log.levels.ERROR)
      return
    end
  end

  vim.cmd("edit " .. vim.fn.fnameescape(note_path))
end

function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local client = pick_client(bufnr)
  if not client then
    vim.notify("No LSP client attached to current buffer.", vim.log.levels.ERROR)
    return
  end

  local ctx, err = build_context(client, bufnr)
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local class_sym = ctx.class_symbol
  local file = ctx.file or vim.api.nvim_buf_get_name(bufnr)
  local root_dir = client.config.root_dir or vim.fn.getcwd()

  local hover = hover_lines(client, bufnr, class_sym, ctx.symbol_uri)
  local supers, subs = get_hierarchy(client, bufnr, class_sym, ctx.symbol_uri)
  local refs, ref_files = get_references(client, bufnr, class_sym, ctx.symbol_uri)
  local outgoing_files, outgoing_total = get_outgoing_hotspots(
    client,
    bufnr,
    ctx.fq_name,
    ctx.class_name ~= "" and ctx.class_name or class_sym.name
  )
  local related = get_workspace_symbols(client, bufnr, ctx.class_name ~= "" and ctx.class_name or class_sym.name, ctx.fq_name, file)
  local note, note_store = load_note(root_dir, ctx.fq_name, ctx.class_name ~= "" and ctx.class_name or class_sym.name, file)
  local note_lines = format_note_lines(note, note_store)

  local buf, win = open_dossier_window(ctx.fq_name)

  render(buf, win, {
    bufnr = bufnr,
    client_id = client.id,
    client_name = client.name,
    root_dir = root_dir,
    file = file,
    fq_name = ctx.fq_name,
    class_symbol = class_sym,
    symbol_uri = ctx.symbol_uri,
    hover = hover,
    supers = supers,
    subs = subs,
    refs = refs,
    ref_files = ref_files,
    outgoing_files = outgoing_files,
    outgoing_total = outgoing_total,
    related = related,
    fields = ctx.fields,
    methods = ctx.methods,
    note_lines = note_lines,
    source_win = source_win,
  })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("ClassDossier", function()
    require("class_dossier").open()
  end, {
    desc = "Open a class-centered dossier for the file's main class",
  })

  vim.api.nvim_create_user_command("ClassNoteEdit", function()
    require("class_dossier").edit_note()
  end, {
    desc = "Open or create the markdown note for the file's main class",
  })

  vim.api.nvim_create_user_command("ClassDossierNotesScope", function(cmd)
    require("class_dossier").set_notes_scope(cmd.args)
  end, {
    nargs = 1,
    complete = function()
      return { "project", "global" }
    end,
    desc = "Set ClassDossier note storage scope: project or global",
  })
end

return M
