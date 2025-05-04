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

M.config = {
  clang_power_tools_script_path = nil,
  vcvarsall_path_override = nil, -- Optional: For users if vswhere fails
  compile_commands_output_dir = nil, -- Optional: Where to place the json file (defaults to cwd)
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

local function find_vswhere()
  -- Look in common locations
  local prog_files = vim.env.ProgramFiles -- e.g., C:\Program Files
  local prog_files_x86 = vim.env['ProgramFiles(x86)'] -- e.g., C:\Program Files (x86)

  local paths_to_check = {}
  if prog_files_x86 then
    table.insert(paths_to_check, prog_files_x86 .. '\\Microsoft Visual Studio\\Installer\\vswhere.exe')
  end
  if prog_files then
    table.insert(paths_to_check, prog_files .. '\\Microsoft Visual Studio\\Installer\\vswhere.exe')
  end
  -- Maybe check PATH environment variable too? (less reliable for specific tools)

  for _, path in ipairs(paths_to_check) do
    if vim.fn.filereadable(path) == 1 then
      notify('Found vswhere at: ' .. path, vim.log.levels.DEBUG)
      return path
    end
  end

  notify('vswhere.exe not found in standard locations.', vim.log.levels.WARN)
  return nil
end

local function get_visual_studio_path()
  local vswhere_path = find_vswhere()
  if not vswhere_path then
    return nil
  end

  -- Use -latest to get the most recent installation
  -- Use -property installationPath to get the root directory
  -- Use -prerelease if you want to include preview versions (optional)
  local cmd = { vswhere_path, '-latest', '-property', 'installationPath', '-nologo' }
  notify('Running vswhere command: ' .. table.concat(cmd, ' '), vim.log.levels.DEBUG)

  -- Use vim.fn.systemlist to capture output as lines
  local result = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 or #result == 0 or result[1] == '' then
    notify('vswhere failed or returned no path. Error code: ' .. vim.v.shell_error, vim.log.levels.ERROR)
    if #result > 0 then
      notify('vswhere output: ' .. table.concat(result, '\n'), vim.log.levels.DEBUG)
    end
    return nil
  end

  local vs_path = vim.trim(result[1]) -- Get the first line of output and trim whitespace
  notify('Detected Visual Studio installation path: ' .. vs_path, vim.log.levels.INFO)
  return vs_path
end

local function get_vcvars_path()
  -- Check override first
  if M.config.vcvarsall_path_override and vim.fn.filereadable(M.config.vcvarsall_path_override) == 1 then
    notify('Using configured vcvarsall_path_override: ' .. M.config.vcvarsall_path_override, vim.log.levels.INFO)
    return M.config.vcvarsall_path_override
  end

  local vs_path = get_visual_studio_path()
  if not vs_path then
    notify('Cannot find vcvarsall.bat because Visual Studio path could not be determined.', vim.log.levels.ERROR)
    return nil
  end

  -- Construct the typical relative path
  local vcvars_path = vs_path .. '\\VC\\Auxiliary\\Build\\vcvarsall.bat'

  if vim.fn.filereadable(vcvars_path) == 1 then
    notify('Found vcvarsall.bat at: ' .. vcvars_path, vim.log.levels.DEBUG)
    return vcvars_path
  else
    notify('vcvarsall.bat not found at expected location: ' .. vcvars_path, vim.log.levels.ERROR)
    return nil
  end
end

-- lua/vs_selector/init.lua

-- Maps platform names from .vcxproj (<Platform> tag) to the [arch] argument
-- needed by vcvarsall.bat for setting up the build environment.
-- This assumes the user wants to build FOR the target platform using the NATIVE host tools.
-- e.g., On an x64 machine, selecting Platform "Win32" sets up the x86 tools.
-- Selecting Platform "x64" sets up the amd64 tools.
local function map_platform_to_vcvars_arch(platform)
  if not platform then
    return nil
  end
  local p_lower = platform:lower()

  if p_lower == 'win32' then
    -- For building 32-bit applications
    return 'x86'
  elseif p_lower == 'x64' then
    -- For building 64-bit applications (using amd64 toolset)
    return 'amd64'
  elseif p_lower == 'arm64' then
    -- For building ARM64 applications
    return 'arm64'
  elseif p_lower == 'arm' then
    -- For building ARM32 applications (less common now)
    return 'arm'
    -- Add other potential Platform names from vcxproj if necessary
    -- else if p_lower == "itanium" then return "ia64" -- Example (very old)
  else
    notify("Unsupported Platform '" .. platform .. "' for vcvarsall.bat [arch] mapping. Cannot determine argument.", vim.log.levels.ERROR)
    return nil
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

function M.generate_compile_commands()
  notify('Attempting to generate compile_commands.json...', vim.log.levels.INFO)

  -- 1. Check prerequisites
  if not M.state.solution then
    notify('No solution selected. Please use :VSSelect first.', vim.log.levels.ERROR)
    return
  end
  if not M.state.project then -- Maybe allow generating for whole solution later? For now require project.
    notify('No project selected. Please use :VSSelect first.', vim.log.levels.ERROR)
    return
  end
  if not M.state.platform then
    notify('No platform selected. Please use :VSSelect first.', vim.log.levels.ERROR)
    return
  end
  if not M.state.configuration then
    notify('No configuration selected. Please use :VSSelect first.', vim.log.levels.ERROR)
    return
  end
  if not M.config.clang_power_tools_script_path or vim.fn.filereadable(M.config.clang_power_tools_script_path) ~= 1 then
    notify('Clang Power Tools script path is not configured or not found: ' .. tostring(M.config.clang_power_tools_script_path), vim.log.levels.ERROR)
    return
  end

  -- 2. Get vcvars path and map platform
  local vcvars_path = get_vcvars_path()
  if not vcvars_path then
    return
  end -- Error message already shown by get_vcvars_path

  local arch = map_platform_to_vcvars_arch(M.state.platform)
  if not arch then
    return
  end -- Error message already shown

  -- 3. Determine output path
  local output_dir = M.config.compile_commands_output_dir or vim.fn.getcwd()
  -- Ensure output dir exists? Powershell might handle it, but could be safer.
  if vim.fn.isdirectory(output_dir) == 0 then
    notify('Output directory does not exist: ' .. output_dir .. '. Attempting to create.', vim.log.levels.WARN)
    vim.fn.mkdir(output_dir, 'p') -- Create parent directories if needed
    if vim.fn.isdirectory(output_dir) == 0 then
      notify('Failed to create output directory: ' .. output_dir, vim.log.levels.ERROR)
      return
    end
  end
  local output_json_path = output_dir .. '\\compile_commands.json'
  notify('Output path set to: ' .. output_json_path, vim.log.levels.DEBUG)

  -- 4. Construct the commands for the temporary batch script
  -- Use 'call' for vcvarsall so environment variables persist for the next command
  local cmd_vcvars = string.format('call "%s" %s', vcvars_path, arch)

  -- Construct the PowerShell command
  -- NOTE: Parameter names (-solution, -configuration, -platform, -output) are assumed based on typical usage.
  -- You MAY need to adjust these based on the actual ExportCompilationDatabase.ps1 script signature!
  local cmd_powershell = string.format(
    'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%s" -export-jsondb -proj "%s" -active-config "%s|%s"',
    M.config.clang_power_tools_script_path,
    M.state.project,
    M.state.configuration,
    M.state.platform, -- Use the original platform name here
    output_json_path
  )
  notify('Compile command: ' .. cmd_powershell, vim.log.levels.DEBUG)

  -- 5. Create and run the temporary batch script
  local temp_bat_path = vim.fn.tempname() .. '.bat'
  notify('Creating temporary batch script: ' .. temp_bat_path, vim.log.levels.DEBUG)

  local file = io.open(temp_bat_path, 'w')
  if not file then
    notify('Failed to create temporary batch file: ' .. temp_bat_path, vim.log.levels.ERROR)
    return
  end
  file:write '@echo off\n' -- Suppress command echoing in the batch script itself
  file:write(cmd_vcvars .. '\n')
  file:write(cmd_powershell .. '\n')
  file:close()

  notify('Running command: cmd /c ' .. temp_bat_path, vim.log.levels.INFO)

  vim.system({ 'cmd', '/c', temp_bat_path }, { text = true }, function(result)
    vim.schedule(function()
      notify('Compile command generation process finished.', vim.log.levels.INFO)

      if result.code == 0 then
        notify('Successfully generated: ' .. output_json_path, vim.log.levels.INFO)
        -- Optionally check if the file actually exists now
        if vim.fn.filereadable(output_json_path) ~= 1 then
          notify('Warning: Command succeeded but output file not found: ' .. output_json_path, vim.log.levels.WARN)
        end
      else
        notify('Error generating compile commands (Exit Code: ' .. result.code .. ').', vim.log.levels.ERROR)
      end

      -- Print stdout/stderr regardless of success/failure for debugging
      if result.stdout and vim.trim(result.stdout) ~= '' then
        notify('stdout:\n' .. result.stdout, vim.log.levels.DEBUG)
      end
      if result.stderr and vim.trim(result.stderr) ~= '' then
        notify('stderr:\n' .. result.stderr, vim.log.levels.ERROR) -- Log stderr as error
      end

      -- Clean up the temporary batch file
      local deleted = pcall(vim.uv.fs_unlink, temp_bat_path)
      if not deleted then
        notify('Warning: Failed to delete temporary file: ' .. temp_bat_path, vim.log.levels.WARN)
      end
    end)
  end)
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
  M.config = vim.tbl_deep_extend('force', M.config, opts or {}) -- Merge user opts

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

  vim.api.nvim_create_user_command(
    'VSGenerateCompileCommands',
    M.generate_compile_commands, -- Reference the function directly
    {
      nargs = 0,
      desc = 'Generate compile_commands.json using Clang Power Tools',
    }
  )

  notify('VS Selector initialized.', vim.log.levels.DEBUG)
  if not M.config.clang_power_tools_script_path then
    notify('Clang Power Tools script path not configured. :VSGenerateCompileCommands will not work.', vim.log.levels.WARN)
  end
end

-- Return the module table
return M
