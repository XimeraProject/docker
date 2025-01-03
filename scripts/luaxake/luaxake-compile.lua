local M = {}
local lfs = require "lfs"
local error_logparser = require("make4ht-errorlogparser")
local pl = require "penlight"
local path = pl.path
local pldir = pl.dir
local plfile = pl.file
local html = require "luaxake-transform-html"
local files = require "luaxake-files"      -- for get_fileinfo
local frost = require "luaxake-frost"      -- for osExecute
local socket = require "socket"

local log = logging.new("compile")


local function parse_log_file(filename)
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

-- Function to find the first table with a given key/value using Penlight
local function find_entry(array, key, value)
  for _, entry in ipairs(array) do
      if entry[key] == value then

          return entry  -- Return the first matching entry
      end
  end
  return nil  -- Return nil if no match is found
end

--
-- These next functions are/can be called by post_command in config.commands
-- HACK: these currently need to be global; TODO: fix!
--
function post_process_html(src_filename, file, cmd_meta, root_dir)
  -- simple wrapper to make it work in post_command
  --
  return html.post_process_html(src_filename, file, cmd_meta, root_dir)
end

function post_process_pdf(src_filename, file, cmd_meta, root_dir)
  -- move the pdf to a corresponding folder under root_dir (presumably ximera-downloads, with different path/name!)
  --
  local folder = string.format("%s/%s/%s",root_dir, cmd_meta.download_folder, file.relative_dir)
  -- local tgt = string.format("%s/%s.%s", folder, file.basename, cmd_meta.extension)
  local tgt = string.format("%s/%s.%s", folder, file.basename, "pdf")
  -- require 'pl.pretty'.dump(src)
  if not path.exists(src_filename) then
    log:warningf("Output file %s does not exists (for %s)",src_filename, file.relative_path)
  else
    log:infof("Moving %s to %s", src_filename, tgt)
    pldir.makepath(folder)
    plfile.copy(src_filename, tgt)
  end

  if file.relative_path:match("_pdf.tex$" ) then
    log:infof("Convert _pdf.pdf file to svg for  %s",file.relative_path) 
    -- Mmm, osExecute should better be elsewhere ...,
    frost.osExecute("pdf2svg " .. file.absolute_path:gsub(".tex",".pdf") .. " " .. file.absolute_path:gsub(".tex",".svg"))
  end

  return 1, tgt
end

--
--
--


--- run a complete compile-cycle on a given file
--- 
--- SIDE-EFFECT: adds output_files to the file argument !!!
--- 
--- @param file fileinfo file on which the command should be run
--- @param compilers [compiler] list of compilers
--- @param compile_sequence table sequence of keys from the compilers table to be executed
--- @return [compile_info] statuses information from the commands
local function compile(file, compilers, compile_sequence, only_check)
  only_check = only_check or false

  local statuses = {}

  -- Start ALL compilations for this file, in the correct order; stop as soon as one fails...
  -- NOTE: extension is a bad name, it's rather  'compiler'
  for _, extension in ipairs(compile_sequence) do
    local command_metadata = compilers[extension]

    if not command_metadata then
      log:errorf("No compiler defined for %s (%s); SKIPPING",extension,file.relative_path)
      goto endofthiscompilation  -- nice: a goto-statement !!!
    end
    if file.extension ~= "tex" then
      log:errorf("Can't compile non-tex file %s; SKIPPING, SHOULD PROBABLY NOT HAVE HAPPENED",file.relative_path)
      goto endofthiscompilation 
    end
    
    if extension:match("html$") and ( file.relative_path:match("_pdf.tex$") or file.relative_path:match("_beamer.tex$") ) then
      log:infof("Skipping HTML compilation of pdf-only file %s",file.relative_path) 

      local filename = file.absolute_path:gsub(".tex$",".html")
      local file, err = io.open(filename, "r")
    
      if file then
          -- File exists, update modification time
          file:close()
          lfs.touch(filename)
      else
          -- File doesn't exist, create a new one
          file, err = io.open(filename, "w")
          if file then
              file:close()
          else
              log:infof("Failed to fix dummy htmlfile %s: %s",filename,err)
          end
      end

      goto endofthiscompilation 
    end
  

    --
    -- WARNING: (tex-)compilation HAS TO START IN THE SUBFOLDER !!!
    --   !!! CHDIR  might confuse all relative paths !!!!
    --
    local current_dir = lfs.currentdir()
    log:tracef("Changing directory to %s (for actual compilations, from %s)",file.absolute_dir,current_dir)
    lfs.chdir(file.absolute_dir)


    local infix = ""
    if command_metadata.infix and command_metadata.infix ~= "" then
      infix = command_metadata.infix.."."
    end
    local output_file = file.filename:gsub("tex$", extension)
    local log_file    = file.filename:gsub("tex$", infix.."log")

    -- sometimes compiler wants to check for the output file (like for sagetex.sage),
    if command_metadata.check_file and not path.exists(output_file) then
      log:debugf("Skipping compilation because 'check_file' and file %s does not exist",output_file)
      goto endofthiscompilation  -- nice: a goto-statement !!!
    end
    
    -- if not output_file.needs_compilation then
    --   log:debugf("Skipping compilation file %s is uptodate",output_file)
    --   goto endofthiscompilation  -- nice: a goto-statement !!!
    -- end

      -- replace placeholders like @{filename} with the corresponding keys (from the metadata table, or config)
      local command = command_metadata.command
      command = command:gsub("@{(.-)}", file)
      command = command:gsub("@{(.-)}", { output_file = output_file })        -- used for sage ...
      command = command:gsub("@{(.-)}", config)

      local start_time =  socket.gettime()
      local compilation_time = 0
      local status = 0
      local output = ""

      if only_check then
        log:info("Running in check-modus: SKIPPING " .. command )
      else
        log:info("Running " .. command )


        -- we reuse this file from make4ht's mkutils.lua
        local f = io.popen(command, "r")
        output = f:read("*all")
        -- rc will contain return codes of the executed command
        local rc =  {f:close()}
        -- the status code is on the third position 
        -- https://stackoverflow.com/a/14031974/2467963
        status = rc[3]
        local end_time = socket.gettime()
        compilation_time = end_time - start_time


        log:debugf("Compilation of %s for %s ended: returns %d (expected %d) after %3f seconds", extension, file.relative_path, status, command_metadata.status,compilation_time)
      end


      --- @class compile_info
      --- @field source_file string source file name
      --- @field output_file string output file name
      --- @field log_file string logging file name
      --- @field command string executed command
      --- @field output string stdout from the command
      --- @field status number status code returned by command
      --- @field errors? table errors detected in the log file
      --- @field post_status? boolean did HTML processing run without errors?
      --- @field post_message? string possible error message from HTML post-processing
      local compile_info = {
        source_file = file.relative_path,
        output_file = output_file,
        log_file    = log_file,
        compiler    = extension,
        command     = command,
        output      = output,
        status      = status
      }
      if command_metadata.check_log then
        local errors = parse_log_file(log_file)  -- gets errors the make4ht-way !
        compile_info.errors = errors
        
        for i, err in ipairs(errors) do
          if i>5 then
            log:errorf("... skipping further errorlog; %d errors found", #errors)
            break
          end
          log:errorf("%-20s: %s [[%s]]", log_file, err.error, err.context)
        end
      end


    if status ~= command_metadata.status then
      log:errorf("Compilation of %s for %s failed: returns %d (not %d) after %3f seconds", extension, file.relative_path, status, command_metadata.status,compilation_time)
      if path.exists(output_file) then
        -- prevent  trailing non-correct files, as they prevent automatic re-compilation !
        log:infof("Moving failed output file to %s", output_file..".failed")
        pl.file.move(output_file, output_file..".failed")
      end
      goto endofthiscompilation  -- nice: a goto-statement !!!
    end

    if command_metadata.post_command then
      local cmd = command_metadata.post_command
      log:infof("Postprocessing: %s", cmd)
      -- call the post_command
      local status, msg = _G[cmd](output_file, file, command_metadata, current_dir)     -- lua way of calling the function whose name is in 'cmd'
      
      if not status then
        log:errorf("Error in postprocessing: %s", msg)
        compiled_file = nil
      else 
        compiled_file = msg
      end
    end

    if compiled_file then
      log:debugf("Adding outputfile %s to %s ", compiled_file, file.relative_path)
      file.output_files[compiled_file] = files.get_fileinfo(compiled_file) 
      -- require 'pl.pretty'.dump(file)
    end

      
      table.insert(statuses, compile_info)

      log:info(string.format("Compilation of %s took %.1f seconds (%.20s)", output_file, compilation_time, file.title))

      log:tracef("Changing directory back to %s (from %s)",current_dir, file.absolute_dir)
      lfs.chdir(current_dir)


      -- -- NOT IMPLEMENTED ...
      -- if status == command_metadata.fatal_status then
      --   log:warning("Skipping further compilations for %s after error",file.relative_file)
      --   break   -- STOP FURTHER COMPILATION
      -- end

    log:tracef("Ended compilation %s", extension)
    ::endofthiscompilation::
  end

  -- if dump_metadata then
  --   log:debug("Dumping new metadata for ".. relative_file )
  --   require 'pl.pretty'.dump(metadata)
  -- end

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
        log:errorf("%20s line %s: %s", status.source_file or "?", err.line or "?", err.error)
        log:error(err.context)
      end
    end
  end
end

--- remove temporary files
---@param basefile fileinfo 
---@param extensions table    list of extensions of files to be removed
---@return  number nfiles     number of files removed
local function clean(basefile, extensions, only_check)
  only_check = only_check or false
  local nfiles = 0
  local basename = path.splitext(basefile.absolute_path)
  log:tracef("%s temp files for %s (%s)", (only_check and "Would remove" or "Removing"), basename, basefile.absolute_path)
  for _, ext in ipairs(extensions) do
    local filename = basename .. "." .. ext
    if path.exists(filename) then
      log:debugf("%s  %s file %s", (only_check and "Would remove" or "Removing") ,ext, filename)
      if not only_check then os.remove(filename); nfiles = nfiles + 1 end
    end
  end
  return nfiles
end

M.compile      = compile
M.print_errors = print_errors
M.clean        = clean

return M
