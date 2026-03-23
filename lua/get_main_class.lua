local M = {}

--- CamelCase → snake + lower (runs on original case first)
local function normalize_to_words(str)
  if not str or str == "" then return {} end
  local s = str:gsub("(%l)(%u)", "%1_%2"):gsub("(%u)(%u%l)", "%1_%2")
  s = s:gsub("^_+", ""):gsub("_+$", "")
  local words = {}
  for part in s:gmatch("[^_]+") do
    if #part >= 2 then
      table.insert(words, part:lower())
    end
  end
  return words
end

--- Hard filename match score (your rule: class name must be in filename)
local function word_match_score(bare_name, filename_words)
  local class_words = normalize_to_words(bare_name)
  if #class_words == 0 then return 0 end

  local fname_set = {}
  for _, w in ipairs(filename_words) do fname_set[w] = true end

  local matched = 0
  for _, cw in ipairs(class_words) do
    if fname_set[cw] then matched = matched + 1 end
  end
  if matched == 0 then return 0 end

  local score = matched * 45
  -- Tail bonus (most common pattern)
  if #filename_words >= 1 and class_words[#class_words] == filename_words[#filename_words] then
    score = score + 65
  end
  if matched >= 2 then score = score + 40 end
  return math.floor(score)
end

local function count_impls(bare_name, text)
  local count = 0
  local pos = 1
  local pattern = bare_name .. "%s*::"
  while true do
    pos = text:find(pattern, pos, true)
    if not pos then break end
    count = count + 1
    pos = pos + #bare_name
  end
  return count
end

local function get_enclosing_namespace(decl_node, bufnr)
  local parts = {}
  local cur = decl_node
  while cur do
    if cur:type() == "namespace_definition" then
      local names = cur:field("name")
      if names and #names > 0 then
        local txt = vim.treesitter.get_node_text(names[1], bufnr)
        if txt and txt ~= "" then table.insert(parts, 1, txt) end
      end
    end
    cur = cur:parent()
  end
  return table.concat(parts, "::")
end

local function extract_namespace_fallback(text)
  return text:match("namespace%s+(__?[%w_]+)") or ""
end

function M.get_main_class()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
  if filename == "" then return nil end

  local filename_words = normalize_to_words(filename)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  local candidates = {}
  local seen = {}

  -- 1. Tree-sitter class/struct declarations (works perfectly in .h files)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if ok and parser then
    local root = parser:parse()[1]:root()
    local query = vim.treesitter.query.parse("cpp", [[
      [
        (class_specifier name: (_) @name)
        (struct_specifier name: (_) @name)
      ]
    ]])

    for id, node in query:iter_captures(root, bufnr) do
      if query.captures[id] == "name" then
        local raw = vim.treesitter.get_node_text(node, bufnr)
        if raw and not seen[raw] then
          seen[raw] = true
          local bare = raw:match("::([^:]+)$") or raw   -- handle rare qualified names
          local wscore = word_match_score(bare, filename_words)
          if wscore >= 70 then
            local decl_node = node:parent()
            local ns = get_enclosing_namespace(decl_node, bufnr)
            local impls = count_impls(bare, text)
            local score = wscore + impls * 25 + 100   -- strong bonus for real declaration
            table.insert(candidates, {
              bare_name = bare,
              namespace = ns,
              score = score,
              impl_count = impls,
            })
          end
        end
      end
    end
  end

  -- 2. Regex scan for ClassName:: implementations (works perfectly in .cpp files)
  for bare in text:gmatch("([A-Z][A-Za-z0-9_]*)%s*::") do
    if not seen[bare] and #bare >= 5 then
      seen[bare] = true
      local wscore = word_match_score(bare, filename_words)
      if wscore >= 70 then
        local impls = count_impls(bare, text)
        local score = wscore + impls * 35
        table.insert(candidates, {
          bare_name = bare,
          namespace = "",
          score = score,
          impl_count = impls,
        })
      end
    end
  end

  if #candidates == 0 then
    vim.notify("No class matching filename heuristic in " .. filename, vim.log.levels.WARN)
    return nil
  end

  table.sort(candidates, function(a, b) return a.score > b.score end)
  local best = candidates[1]

  -- Fill namespace if missing from declaration path
  if best.namespace == "" then
    best.namespace = extract_namespace_fallback(text)
  end

  local full = best.namespace ~= "" and best.namespace .. "::" .. best.bare_name or best.bare_name

  -- Uncomment next line to see internal scoring
  -- vim.print({ picked = best.bare_name, namespace = best.namespace, score = best.score, impls = best.impl_count })

  return {
    namespace = best.namespace,
    identifier = best.bare_name,
    full_qualified = full,
  }
end

return M
