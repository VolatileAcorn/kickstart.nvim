-- lua/vs_selector/init.lua

local M = {}

-- Store the state globally within this module
M.state = {
  solution = nil, -- Full path to the selected .sln file
  project = nil, -- Full path to the selected .vcxproj file
  platform = nil, -- Selected platform string
  configuration = nil, -- Selected configuration string
  available_platforms = {}, -- Platforms found in the selected project
  available_configurations = {}, -- Configurations found in the selected project
  found_slns = {}, -- List of found .sln file paths
  found_vscprojs = {}, -- List of found .vcxproj file paths
}

-- =============================================
-- Helper Functions (Internal)
-- =============================================

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'VS Selector' })
end

local function get_relative_path(path)
  -- Ensure path is a string before proceeding (robustness)
  if type(path) ~= 'string' then
    return path
  end -- Return original if not a string

  -- On Windows, vim.fn.getcwd() might use backslashes
  -- On Unix, it uses forward slashes
  local cwd = vim.fn.getcwd()
  local path_norm = path:gsub('\\', '/') -- Normalize path
  local cwd_norm = cwd:gsub('\\', '/') -- Normalize cwd
  if cwd_norm:sub(-1) ~= '/' then -- Ensure trailing slash on cwd
    cwd_norm = cwd_norm .. '/'
  end

  -- Case-insensitive comparison needed? Yes, especially for Windows.
  local path_compare = path_norm
  local cwd_compare = cwd_norm
  if vim.fn.has 'win32' == 1 then
    path_compare = path_norm:lower()
    cwd_compare = cwd_norm:lower()
  end

  -- Check if path_compare starts with cwd_compare using string.find
  -- string.find(haystack, needle, start_index, plain_match)
  -- plain_match=true disables pattern matching
  -- returns the start index if found, otherwise nil
  if path_compare:find(cwd_compare, 1, true) == 1 then
    -- Return the part of the original normalized path after the CWD part
    return path_norm:sub(#cwd_norm + 1)
  end
end

-- Finds .sln and .vcxproj files recursively from cwd
local function find_files()
  local cwd = vim.fn.getcwd()
  notify('Scanning for .sln and .vcxproj files in ' .. cwd, vim.log.levels.DEBUG)

  -- Use globpath for recursive search, return absolute paths
  M.state.found_slns = vim.fn.globpath(cwd, '**/*.sln', true, true)
  M.state.found_vscprojs = vim.fn.globpath(cwd, '**/*.vcxproj', true, true)

  if #M.state.found_slns == 0 then
    notify('No .sln files found in the current directory tree.', vim.log.levels.WARN)
    -- Don't return false yet, maybe only projects exist
  end
  if #M.state.found_vscprojs == 0 then
    notify('No .vcxproj files found in the current directory tree.', vim.log.levels.WARN)
    return false -- Need projects to proceed
  end

  notify(string.format('Found %d solution(s) and %d project(s).', #M.state.found_slns, #M.state.found_vscprojs), vim.log.levels.DEBUG)
  return true
end

-- Parses a .vcxproj file to extract platforms and configurations
function parse_vcxproj(filepath)
  notify('Parsing project file: ' .. get_relative_path(filepath), vim.log.levels.DEBUG)
  local platforms = {}
  local configurations = {}
  local platform_set = {}
  local configuration_set = {}

  local file = io.open(filepath, 'r')
  if not file then
    notify('Error opening project file: ' .. filepath, vim.log.levels.ERROR)
    return {}, {}
  end

  -- Simple parsing: Look for <Platform>...</Platform> and <Configuration>...</Configuration>
  -- inside ItemDefinitionGroup or ProjectConfiguration elements. This is fragile.
  local in_config_group = false
  for line in file:lines() do
    -- Look for the start of relevant groups
    if line:match '<PropertyGroup Label="Configuration"' or line:match '<ItemDefinitionGroup Condition=' or line:match '<ProjectConfiguration' then
      in_config_group = true
    elseif line:match '</PropertyGroup>' or line:match '</ItemDefinitionGroup>' or line:match '</ProjectConfiguration>' then
      in_config_group = false
    end

    -- Only capture if we think we are in a relevant section
    if in_config_group then
      local plat = line:match '<Platform>(.*)</Platform>'
      if plat and not platform_set[plat] then
        table.insert(platforms, plat)
        platform_set[plat] = true
      end
      local conf = line:match '<Configuration>(.*)</Configuration>'
      if conf and not configuration_set[conf] then
        -- Add filtering for potentially unwanted default entries if needed
        -- e.g., if conf ~= 'Debug' and conf ~= 'Release' etc.
        table.insert(configurations, conf)
        configuration_set[conf] = true
      end
    end

    -- Alternative simpler approach (less accurate, might grab unwanted tags):
    -- local plat = line:match("<Platform>(.*)</Platform>")
    -- if plat and not platform_set[plat] then table.insert(platforms, plat); platform_set[plat] = true; end
    -- local conf = line:match("<Configuration>(.*)</Configuration>")
    -- if conf and not configuration_set[conf] and conf ~= "Globals" and conf ~= "'$(Configuration)'" then table.insert(configurations, conf); configuration_set[conf] = true; end
  end

  file:close()

  -- Clean up potential duplicates from parsing method (though set should handle it)
  local function unique(tbl)
    local seen = {}
    local res = {}
    for _, v in ipairs(tbl) do
      if not seen[v] then
        table.insert(res, v)
        seen[v] = true
      end
    end
    return res
  end

  platforms = unique(platforms)
  configurations = unique(configurations)

  table.sort(platforms)
  table.sort(configurations)

  notify(string.format('Found Platforms: %s', table.concat(platforms, ', ')), vim.log.levels.DEBUG)
  notify(string.format('Found Configurations: %s', table.concat(configurations, ', ')), vim.log.levels.DEBUG)

  return platforms, configurations
end

-- =============================================
-- Selection Workflow Functions (Internal)
-- =============================================

-- Step 1: Select Solution (optional)
local function select_solution_step()
  if #M.state.found_slns > 0 then
    local sln_choices = {}
    for _, path in ipairs(M.state.found_slns) do
      table.insert(sln_choices, get_relative_path(path))
    end
    vim.ui.select(sln_choices, { prompt = 'Select Solution:' }, function(choice)
      if not choice then
        notify('Solution selection cancelled.', vim.log.levels.WARN)
        return -- Exit if user cancelled
      end
      -- Find the absolute path corresponding to the relative choice
      for _, path in ipairs(M.state.found_slns) do
        if get_relative_path(path) == choice then
          M.state.solution = path -- Store selected solution
          break
        end
      end
      M.select_project_step() -- Proceed to project selection
    end)
  else
    -- If no solutions found, proceed directly to project selection
    M.select_project_step()
  end
end

-- Step 2: Select Project
function M.select_project_step() -- Make this accessible if needed directly? Maybe not. Keep local for now.
  local function select_project_step_internal()
    if #M.state.found_vscprojs == 0 then
      notify('No .vcxproj files found to select from.', vim.log.levels.ERROR)
      return -- Cannot proceed without projects
    end

    local proj_choices = {}
    for _, path in ipairs(M.state.found_vscprojs) do
      table.insert(proj_choices, get_relative_path(path))
    end
    vim.ui.select(proj_choices, { prompt = 'Select Project:' }, function(choice)
      if not choice then
        notify('Project selection cancelled.', vim.log.levels.WARN)
        return -- Exit if user cancelled
      end
      -- Find the absolute path corresponding to the relative choice
      for _, path in ipairs(M.state.found_vscprojs) do
        if get_relative_path(path) == choice then
          M.state.project = path -- Store selected project immediately
          break
        end
      end
      select_config_step_internal() -- Proceed to parse and select config/platform
    end)
  end
  select_project_step_internal() -- Call the internal version immediately
end

-- Step 3: Select Platform and Configuration
function select_config_step_internal()
  if not M.state.project then
    notify('Internal error: Project not selected.', vim.log.levels.ERROR)
    return
  end

  -- Parse selected project for Platforms and Configurations
  local platforms, configurations = parse_vcxproj(M.state.project)
  M.state.available_platforms = platforms
  M.state.available_configurations = configurations

  if #M.state.available_platforms == 0 then
    notify('No platforms found in ' .. get_relative_path(M.state.project), vim.log.levels.WARN)
  end
  if #M.state.available_configurations == 0 then
    notify('No configurations found in ' .. get_relative_path(M.state.project), vim.log.levels.WARN)
  end

  -- Select Platform (if available)
  if #M.state.available_platforms > 0 then
    vim.ui.select(M.state.available_platforms, { prompt = 'Select Platform:' }, function(platform_choice)
      if not platform_choice then
        notify('Platform selection cancelled.', vim.log.levels.WARN)
        return -- Exit if user cancelled
      end
      M.state.platform = platform_choice
      select_configuration_final_step_internal() -- Proceed to configuration selection
    end)
  else
    -- If no platforms, skip selection and proceed
    M.state.platform = nil
    select_configuration_final_step_internal()
  end
end

-- Step 4: Select Configuration (final step)
function select_configuration_final_step_internal()
  -- Select Configuration (if available)
  if #M.state.available_configurations > 0 then
    vim.ui.select(M.state.available_configurations, { prompt = 'Select Configuration:' }, function(config_choice)
      if not config_choice then
        notify('Configuration selection cancelled.', vim.log.levels.WARN)
        return -- Exit if user cancelled
      end
      M.state.configuration = config_choice
      finalize_selection_internal() -- Finalize and notify
    end)
  else
    -- If no configurations, skip selection
    M.state.configuration = nil
    finalize_selection_internal()
  end
end

-- Step 5: Finalize and Notify
function finalize_selection_internal()
  -- Update state is already done in previous steps

  local msg_parts = {}
  if M.state.solution then
    table.insert(msg_parts, 'Sln: ' .. get_relative_path(M.state.solution))
  end
  if M.state.project then
    table.insert(msg_parts, 'Proj: ' .. get_relative_path(M.state.project))
  end
  if M.state.platform then
    table.insert(msg_parts, 'Plat: ' .. M.state.platform)
  end
  if M.state.configuration then
    table.insert(msg_parts, 'Cfg: ' .. M.state.configuration)
  end

  if #msg_parts > 0 then
    notify('Selected: ' .. table.concat(msg_parts, ' | '))
    vim.cmd 'redrawstatus!' -- Force statusline update
  else
    notify 'No complete selection made.'
  end
end

-- =============================================
-- Public API Functions
-- =============================================

-- Main function exposed to the user command
function M.select_project_and_config()
  -- 1. Find files first
  if not find_files() then
    -- Error message already shown by find_files if no vcxproj found
    return
  end

  -- 2. Start the selection chain
  select_solution_step() -- This will cascade through the steps using callbacks
end

-- Function to clear the current selection
function M.clear_selection()
  M.state.solution = nil
  M.state.project = nil
  M.state.platform = nil
  M.state.configuration = nil
  M.state.available_platforms = {}
  M.state.available_configurations = {}
  -- Optional: Clear found files cache? Maybe keep it unless user explicitly rescans.
  -- M.state.found_slns = {}
  -- M.state.found_vscprojs = {}
  notify('VS Selector state cleared.', vim.log.levels.INFO, { title = 'VS Selector' })
  vim.cmd 'redrawstatus!' -- Update statusline
end

-- Function to be called by the statusline component
function M.get_statusline_info()
  local parts = {}
  -- Show only filenames without extension for brevity
  if M.state.solution then
    table.insert(parts, 'S:' .. vim.fn.fnamemodify(M.state.solution, ':t:r'))
  end
  if M.state.project then
    table.insert(parts, 'P:' .. vim.fn.fnamemodify(M.state.project, ':t:r'))
  end
  if M.state.platform then
    table.insert(parts, M.state.platform)
  end
  if M.state.configuration then
    table.insert(parts, M.state.configuration)
  end

  if #parts > 0 then
    -- Use a Nerd Font icon (e.g., nf-dev-visual_studio) or simple text
    return '󰜌 VS[' .. table.concat(parts, '|') .. ']' -- Gear icon: 󰒓 , VS icon: 󰜌
    -- return "VS[" .. table.concat(parts, "|") .. "]" -- Text fallback
  else
    return '' -- Return empty if nothing is selected
  end
end

-- =============================================
-- Setup Function (Called by user config)
-- =============================================

-- The setup function is responsible for creating commands, mappings, etc.
function M.setup(opts)
  -- opts is an optional table for future configuration options

  -- Standard plugin guard to prevent running setup multiple times
  if vim.g.loaded_vs_selector then
    return
  end
  vim.g.loaded_vs_selector = 1

  -- Create the user command :VSSelect
  vim.api.nvim_create_user_command(
    'VSSelect', -- Command name
    M.select_project_and_config, -- Reference the function directly
    {
      nargs = 0, -- Command takes no arguments
      desc = 'Select Visual Studio Solution, Project, Platform, and Configuration', -- Description for :help
    }
  )

  -- Create the user command :VSClear
  vim.api.nvim_create_user_command(
    'VSClear',
    M.clear_selection, -- Reference the function directly
    {
      nargs = 0,
      desc = 'Clear the selected Visual Studio configuration',
    }
  )

  notify('VS Selector initialized.', vim.log.levels.DEBUG)
end

-- Return the module table
return M
