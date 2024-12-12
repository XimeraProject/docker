local M = {}
local lfs = require "lfs"
local error_logparser = require("make4ht-errorlogparser")
local pl = require "penlight"
local mkutils = require("mkutils")
local path = pl.path
local html = require "luaxake-transform-html"
local files = require "luaxake-files"      -- for get_metadaa
local socket = require "socket"

local log = logging.new("compile")



--- fill command template with file information
--- @param file metadata file on which the command should be run
--- @param command string command template
--- @return string command 
local function prepare_command(file, command_template)
  -- replace placeholders like @{filename} with the corresponding keys from the metadata table
  return command_template:gsub("@{(.-)}", file)
end


local function test_log_file(filename)
  local f = io.open(filename, "r")
  if not f then 
    log:error("Cannot open log file: " .. filename)
    return nil 
  end
  local content = f:read("*a")
  f:close()
  return error_logparser.parse(content)
end

local function copy_table(tbl)
  local t = {}
  for k,v in pairs(tbl) do 
    if type(v) == "table" then
      t[k] = copy_table(v)
    else
      t[k] = v 
    end
  end
  return t
end

--- run a command
--- @param file metadata file on which the command should be run
--- @param compilers [compiler] list of compilers
--- @param compile_sequence table sequence of keys from the compilers table to be executed
--- @return [compile_info] statuses information from the commands
local function compile(file, compilers, compile_sequence)
  
  --
  -- WARNING: (tex-)compilation STARTS IN THE SUBFOLDER !!!
  --
  local current_dir = lfs.currentdir()
  lfs.chdir(file.absolute_dir)

  local statuses = {}
  local FAIL = false

  -- Start ALL compilations for this file, in the correct order; stop as soon as one fails...
  for _, extension in ipairs(compile_sequence) do
    local command_metadata = compilers[extension]

    if not command_metadata then
      log:errorf("No compiler defined for %s (%s)",extension,file.relative_path)
      error("No compiler defined for "..extension)
    end

    local output_file = file.filename:gsub("tex$", extension)
    if command_metadata and command_metadata.check_file then
      -- sometimes compiler wants to check for the output file (like for sagetex.sage),
      if not mkutils.file_exists(output_file) then
        -- ignore this command if the file doesn't exist
        command_metadata = nil
      end
    end
    -- if command_metadata and output.needs_compilation then
    if command_metadata then
      local command_template = command_metadata.command
      -- we need to make a copy of file metadata to insert some additional fields without modification of the original
      -- log:debug("Command " .. command_template)
      local tpl_table = copy_table(file)
      tpl_table.output_file = output_file
      tpl_table.make4ht_extraoptions = config.make4ht_extraoptions
      tpl_table.make4ht_mode = config.make4ht_mode
      local command = prepare_command(tpl_table, command_template)
      local start_time =  socket.gettime()


      log:info("Starting " .. command )
      -- we reuse this file from make4ht's mkutils.lua
      local f = io.popen(command, "r")
      local output = f:read("*all")
      -- rc will contain return codes of the executed command
      local rc =  {f:close()}
      -- the status code is on the third position 
      -- https://stackoverflow.com/a/14031974/2467963
      local status = rc[3]
      local end_time = socket.gettime()
      local compilation_time = end_time - start_time
      if status ~= command_metadata.status then
        log:error("Compilation failed: returns " .. (status or "") ..", but expected ".. command_metadata.status)
        FAIL = true   -- continue for now, to collect logging etc. ...
      end
      --- @class compile_info
      --- @field output_file string output file name
      --- @field command string executed command
      --- @field output string stdout from the command
      --- @field status number status code returned by command
      --- @field errors? table errors detected in the log file
      --- @field html_processing_status? boolean did HTML processing run without errors?
      --- @field html_processing_message? string possible error message from HTML post-processing
      local info = {
        output_file = output_file,
        command = command,
        output = output,
        status = status
      }
      if command_metadata.check_log then
        info.errors = test_log_file(file.basename .. ".log")
      end

      -- store outputfiles with metadata; TODO: check/fix absolute_path
      local ofile = files.get_metadata(file.absolute_dir, output_file)

      log:debug("Adding outputfile "..ofile.relative_path.. " to "..file.relative_path)
      -- require 'pl.pretty'.dump(ofile)
      table.insert(file.output_files,ofile) 
      -- require 'pl.pretty'.dump(file)

      if command_metadata.process_html then
        info.html_processing_status, info.html_processing_message = html.process(file)
        if not info.html_processing_status then
          log:error("Error in HTML post processing: " .. (info.html_processing_message or ""))
        end
      end
      table.insert(statuses, info)
      log:info(string.format("Compilation of %s took %.1f seconds (%.20s)", output_file, compilation_time, file.title))

      if FAIL then
        break   -- STOP FURTHER COMPILATION
      end
  end
  end
  lfs.chdir(current_dir)
  return statuses
end

--- print error messages parsed from the LaTeX log
---@param errors table
local function print_errors(statuses)
  for _, status in ipairs(statuses) do
    local errors = status.errors or {}
    if #errors > 0 then
      log:error("Errors from " .. status.command .. ":")
      for _, err in ipairs(errors) do
        log:error(string.format("%20s line %d: %s", err.filename or "?", err.line or "?", err.error))
        log:error(err.context)
      end
    end
  end
end

--- remove temporary files
---@param basefile metadata 
---@param extensions table list of extensions of files to be removed
local function clean(basefile, extensions)
  local basename = path.splitext(basefile.absolute_path)
  for _, ext in ipairs(extensions) do
    local filename = basename .. "." .. ext
    if mkutils.file_exists(filename) then
      log:debug("Removing temp file: " .. filename)
      os.remove(filename)
    end
  end
end

M.compile      = compile
M.print_errors = print_errors
M.clean        = clean

return M
