local M = {}
local pl = require "penlight"
local graph = require "luaxake-graph"
local log = logging.new("files")
local lfs = require "lfs"

local path = pl.path
local abspath = pl.path.abspath
local tablex = pl.tablex

--- identify, if the file should be ignored
--- @param entry string tested file path
--- @return boolean should_be_ignored if file should be ignored
local function ignore_entry(entry)
  -- files that should be ignored
  if entry:match("^%.") and not entry:match("^%./") then -- ignore 'hidden' files/dirs (i.e that start with a '.')
    log:trace("Ignoring file "..entry)
    return true 
  end
  return false

  -- does not work properly, eg. with clean: just add everything...
  -- local attr = lfs.attributes(entry)
  -- if attr and attr.mode == "directory" then
  --   log:trace("Keeping folder "..entry)
  --   return false
  -- end
  -- local extension = entry:match(".%.([^%.]+)$")
  -- local exts = config.include_extensions
  -- if exts[extension] then
  --   log:trace("Keeping file "..entry)
  --   return false
  -- end
  -- log:tracef("Ignoring file %s (%s)",entry, extension)

  -- return true
end


--- get file extension 
--- @param relative_path string file path
--- @return string extension
local function get_extension(relative_path)
  return relative_path:match("%.([^%.]+)$")
end



--- find TeX4ht config file 
--- @param filename string name of the config file
--- @param directories [string]
--- @return string path of the config file
local function find_config(filename, directories)
  -- the situation with the TeX4ht config file is a bit complicated
  -- it can be placed in the current directory, in the document root directory, 
  -- or in the kpse path. if it cannot be found in any of these places, 
  -- we will set it to config.config_file (presumably ximera.cfg)
  -- in any case, we must provide a full path to the config file, because it will 
  -- be used in different directories. 
  for _, dir in ipairs(directories) do
    local lpath = dir .. "/" .. filename
    if pl.path.exists(lpath) then
      log:trace("find_config found "..filename.. " in ".. lpath.."( from "..table.concat(directories,', ')..")")
      return lpath
    end
  end
  -- if we cannot find the config file in any directory, try to find it using kpse
  local lpath = kpse.find_file(filename, "texmfscripts")
  if lpath then
    log:trace("find_config found "..filename.. " in ".. lpath.."( from kpse texmfscripts)")
    return lpath 
  end
  -- lastly, test if it is a full path to the file
  if pl.path.exists(filename) then 
    log:trace("find_config found "..filename.. " ( as this file happens to exist)")
    return filename
  end
  -- xhtml is default TeX4th config file, use it if we cannot find a user config file
  -- return "xhtml"
  return config.config_file
end

--- get absolute and relative file path, as well as other file metadata
--- @param input_path string filename
--- @return fileinfo
local function get_fileinfo(input_path, root_folder)

  -- local relative_path = path.normpath(relpath)     -- resolve potential ../ parts
  -- dir, entry = path.splitpath(relative_path)

  log:tracef("Getting fileinfo for %s (%s)", input_path, root_folder)

  if ignore_entry(input_path) then
    log:warningf("Collecting fileinfo for ignored file %s (%s).", input_path, root_folder)
    -- return 
  end

  if root_folder and string.match(input_path, "^"..root_folder) then
    input_path = input_path:gsub("^"..root_folder, "")
  end

  local relative_path = path.normpath(input_path)     -- resolve potential ../ parts

  
  --- @class fileinfo
  --- @field relative_path  string        relative path of the file (to the root_folder)
  --- @field absolute_path  string        absolute path of the file
  --- @field absolute_dir   string        absolute directory path of the file
  --- @field filename       string        filename of the file
  --- @field basename       string        filename without extension
  --- @field extension      string        file extension
  --- @field exists         boolean       true if file exists
  --- @field modified       number        last modification time 
  --- @field needs_compilation boolean 
  --- @field depends_on_files  fileinfo[]    list of files the file depends on
  --- @field output_files      fileinfo[]
  --- @field config_file?   string        TeX4ht config file
  --- @field root_folder?   string        root folder
  --- @
  local fileinfo = {}
  
  fileinfo.relative_path = relative_path
  fileinfo.absolute_path = abspath(relative_path)
  -- fileinfo.absolute_dir  = abspath(dir)
  
  fileinfo.exists        = path.exists(relative_path)
  fileinfo.modified      = path.getmtime(relative_path)
  fileinfo.needs_compilation = false
  fileinfo.config_file   = config.config_file     -- always the same, unless overwritten somewhere ?

  fileinfo.relative_dir,  fileinfo.filename      = path.splitpath(relative_path)
  fileinfo.absolute_dir,  _                      = path.splitpath(fileinfo.absolute_path)
  fileinfo.basename,      fileinfo.extension     = fileinfo.filename:match("(.*)%.([^%.]+)$")
  fileinfo.basenameshort, fileinfo.extensionlong = fileinfo.filename:match("([^%.]*)%.(.+)$")


  fileinfo.depends_on_files  = {}
  fileinfo.output_files      = {}


  if config.dump_fileinfo and string.match(relative_path, config.dump_fileinfo) then
    log:debugf("Dumping new fileinfo for %s (%s)", relative_path, fileinfo.modified )
    require 'pl.pretty'.dump(fileinfo)
  end
  return fileinfo
end


--- get fileinfo for all files in a directory and it's subdirectories
--- @param dir string path to the directory
--- @param files? table retrieved files
--- @return fileinfo[]
local function get_files(dir, files)
  dir = dir:gsub("/$", "")    -- remove potential trailing '/'
  files = files or {}
  local initial_nfiles = tablex.size(files)
  for entry in path.dir(dir) do
    if not ignore_entry(entry) then
      local fileinfo = get_fileinfo(dir.."/"..entry)
      local relative_path = fileinfo.relative_path
      if path.isdir(relative_path) then
        files = get_files(relative_path, files)
      elseif path.isfile(relative_path) then
        files[relative_path] = fileinfo
      end
    end
  end
  log:debugf("get_files returns %4d files in %s", tablex.size(files) - initial_nfiles, dir)
  --pl.pretty.dump(files)
  return files
end


function filter_tex_files(tbl)
  local result = {}
  for _, entry in pairs(tbl) do
      if entry.extension == "tex" then
          table.insert(result, entry)
      end
  end
  return result
end

--- add TeX metadata: can it be compiled standalone, is it a ximera or a xourse
--- @param filename string name of the tested TeX file
--- @param linecount number number of lines that should be tested
--- @return boolean is_main true if the file contains \documentclass
local function add_tex_metadata(file, linecount)
  -- we assume that the main TeX file contains \documentclass near beginning of the file 
  linecount = linecount or 30 -- number of lines that will be read
  local filename = file.absolute_path
  local line_no = 0
  for line in io.lines(filename) do
    line_no = line_no + 1
    if line_no > linecount then 
      file.tex_type='no-document'
      break 
    end
    local class_name = line:match("\\documentclass%s*%[[^]]*%]%s*{([^}]+)}")
                    or line:match("\\documentclass%s*{([^}]+)}")
    if class_name then
      file.tex_type = class_name
      -- log:debug("Document class: " .. class_name)
      return true
    end
  end
  return false
end

--- get list of compilable TeX files 
--- @param files metadata[] list of TeX files to be tested
--- @return metadata[] main_tex_files list of main TeX files
local function filter_main_tex_files(files)
  local t = {}
  for _, metadata in ipairs(files) do
    -- if is_main_tex_file(metadata.absolute_path, config.documentclass_lines ) then
    if add_tex_metadata(metadata, config.documentclass_lines ) then
      log:debug("Found main TeX file: " .. metadata.absolute_path.. " ("..metadata.tex_type..")" )
      t[#t+1] = metadata
    else 
      log:debug("Not a MAIN TeX file: " .. metadata.absolute_path)
    end
  end
  return t
end

--- Detect if the output file needs recompilation
---@param tex fileinfo metadata of the main TeX file to be compiled
---@param outfile fileinfo metadata of the output file
---@return boolean
local function needs_compiling(tex, outfile)
  -- if the output file doesn't exist, it needs recompilation
  log:tracef("Does %s need compilation? %s",outfile.relative_path, outfile.exists and "It exists" or "It doesn't exist")
  if not outfile.exists then return true end
  -- test if the output file is older if the main file or any dependency
  local status = tex.modified > outfile.modified
  if status then 
    log:tracef("TeX file %s has changed since compilation of %s",tex.relative_path, outfile.relative_path)
  end
  for _,subfile in ipairs(tex.depends_on_files or {}) do
    --  log:tracef("Check modified of subfile %s", subfile.relative_path)
    if not subfile or not subfile.relative_path or not subfile.modified then
        log:warning("Incomplete data for dependency of %s",tex.relative_path)
        pl.pretty.dump(subfile)
    end
    if subfile.modified > outfile.modified then
      log:tracef("Dependent file %s has changed since compilation of %s",subfile.relative_path,  outfile.relative_path)
      status = status or subfile.modified > outfile.modified
    end
  end
  log:tracef("%s %s", outfile.relative_path, status and "needs compilation" or "does not need compilation")
  return status
end

--- update the list of files included in the given TeX file
--- @param fileinfo fileinfo TeX file metadata
--- @return 
local function update_depends_on_files(fileinfo)
  local filename    = fileinfo.absolute_path
  local current_dir = fileinfo.absolute_dir
  -- local dependecies = config.default_dependencies
  -- table.move(config.default_dependencies, 1, #(config.default_dependencies), 1, dependecies)

  for _, dep in ipairs(config.default_dependencies or {}) do
    fileinfo.depends_on_files[dep] = get_fileinfo(dep)
  end

  local f = io.open(filename, "r")
  if f then
    local content = f:read("*a")
    f:close()
    -- remove all comments
    content = content:gsub("([^\\])%%.-\n", "%1\n")
    -- loop over all LaTeX commands with arguments
    for command, argument in content:gmatch("\\(%w+)%s*{([^%}]+)}") do
      -- add dependency if the current command is \input like
      if config.input_commands[command] then
        local metadata = get_fileinfo(current_dir.."/"..argument)
        if not argument:match(".tex$") and ( not metadata or not metadata.exists ) then
          -- the .tex extension may be missing, so try to read it again
          argument = argument .. ".tex"
          metadata = get_fileinfo(current_dir.."/"..argument)
        end
        if metadata and metadata.exists then
          log:debugf("File %s depends on %s", filename, metadata.absolute_path)
          fileinfo.depends_on_files[metadata.relative_path] = metadata
        else
          log:warningf("%s: No metadata found for %s/%s; not added to dependencies.", filename, current_dir, argument)
        end
      end
    end
  end
  log:debugf("tex_dependencies found %d dependencies for %s", tablex.size(fileinfo.depends_on_files), filename)
  --log:tracef("%s has dependencies %s", filename, table.concat(dependecies,', '))
  return
end


--- check if any output file needs a compilation
--- @param metadata metadata metadata of the TeX file
--- @param extensions table list of extensions
--- @return boolean needs_compilation true if the file needs compilation
--- @return output_file[] list of output files 
local function check_output_files(metadata, extensions, compilers)
  local output_files = {}
  local tex_file = metadata.filename
  local needs_compilation = false
  for _, extension in ipairs(extensions) do
    local html_file = get_fileinfo(metadata.relative_path:gsub("tex$", extension))
    -- local html_file = get_metadata(metadata.absolute_dir, tex_file:gsub("tex$", extension))
    -- detect if the HTML file needs recompilation
    local status = needs_compiling(metadata, html_file)
    -- for some extensions (like sagetex.sage), we need to check if the output file exists 
    -- and stop the compilation if it doesn't
    local compiler = compilers[extension] or {}
    if compiler.check_file and not path.exists(html_file.absolute_path) then
      log:debug("Ignored output file doesn't exist: " .. html_file.absolute_path)
      status = false
    end
    needs_compilation = needs_compilation or status
    log:debugf("%-12s %8s: %s",extension,  status and 'COMPILE' or 'OK', html_file.absolute_path)
    --- @class output_file 
    --- @field needs_compilation boolean true if the file needs compilation
    --- @field metadata metadata of the output file 
    --- @field extension string of the output file
    -- output_files[#output_files+1] = {
    --   needs_compilation = status,
    --   metadata          = html_file,
    --   extension         = extension
    -- }
    -- Mmm, use a 'flatter' structure for output_files ...
    html_file.needs_compilation = status
    html_file.extension         = extension
    output_files[#output_files+1] = html_file
  end
  return needs_compilation, output_files
end

--- create sorted table of files that needs to be compiled 
--- @param tex_files metadata[] list of TeX files metadata
--- @return metadata[] to_be_compiled list of files in order to be compiled
local function sort_dependencies(tex_files, force_compilation)
  -- create a dependency graph for files that needs compilation 
  -- the files that include other courses needs to be compiled after changed courses 
  -- at least that is what the original Xake command did. I am not sure if it is really necessary.
  log:tracef("Sorting dependencies (%s)", force_compilation)

  local Graph = graph:new()
  local used = {}
  local to_be_compiled = {}
  -- first add all used files
  for _, metadata in ipairs(tex_files) do
    log:tracef("Consider %s", metadata.absolute_path)

    if force_compilation or metadata.needs_compilation then
      Graph:add_edge("root", metadata.absolute_path)
      used[metadata.absolute_path] = metadata
    end
  end
  
  -- now add edges to included files which needs to be recompiled
  for _, metadata in pairs(used) do
    local current_name = metadata.absolute_path
    log:tracef("Get used = %s (%s)",current_name,metadata.dependecies)
    for _, child in ipairs(metadata.dependecies or {}) do
      local name = child.absolute_path
      log:tracef("Get child = %s",name)
      -- add edge only to files added in the first run, because only these needs compilation
      if used[name] then
        log:tracef("Added edge %s  - %s", current_name, name)
        Graph:add_edge(current_name, name)
      end
    end
  end
  log:tracef("Topographic sort")

  -- topographic sort of the graph to get dependency sequence
  local sorted, msg = Graph:sort()

  if not sorted then
    log:errorf("Could not sort dependency Graph: %s", msg)
    log:errorf("RETURNING UNSORTED LIST")
    return tex_files
  else
    -- we need to save files in the reversed order, because these needs to be compiled first
  for i = #sorted, 1, -1 do
    local name = sorted[i]
    log:tracef("Adding to be compiled %2d: %s",i,name)
    to_be_compiled[#to_be_compiled+1] = used[name]
  end
  end
  return to_be_compiled
end

--- find TeX files that needs to be compiled in the directory tree
--- @param dir string root directory where we should find TeX files
--- @return metadata[] tex_files list of all TeX files found in the directory tree
local function get_tex_files_with_status(dir, output_formats, compilers)
  log:debugf("Getting tex files in %s (for %s and %s)", dir, table.concat(output_formats,', '), table.concat(compilers,', '))
  local files = get_files(dir)
  local only_tex_files = filter_tex_files(files)
  local tex_files = filter_main_tex_files(only_tex_files)
  -- now check which output files needs a compilation
  for _, metadata in ipairs(tex_files) do
    -- get list of included TeX files
    update_depends_on_files(metadata)
    -- check for the need compilation
    local status, output_files = check_output_files(metadata, output_formats, compilers)
    metadata.needs_compilation = status
    metadata.output_files = output_files
    -- try to find the TeX4ht .cfg file
    -- to speed things up, we will find it only for files that needs a compilation
    if metadata.needs_compilation then
      -- search in the current work dir first, then in  the directory of the TeX file, and project root
      -- TODO: check use of 'config.dir' !!!
      metadata.config_file = find_config(config.config_file, {lfs.currentdir(), metadata.absolute_dir, abspath(dir)})
      if metadata.config_file ~= config.config_file then log:debug("Use config file: " .. metadata.config_file) end
    end
    if status then
      log:infof("%-12s %8s: %s", metadata.extension,  status and 'CHANGED' or 'OK', metadata.absolute_path)
    else
      log:debugf("%-12s %8s: %s", metadata.extension,  status and 'CHANGED' or 'OK', metadata.absolute_path)
    end
  end

  -- SKIPPED: create ordered list of files that needs to be compiled
  return tex_files
end


M.get_tex_files_with_status = get_tex_files_with_status
M.sort_dependencies = sort_dependencies
M.get_fileinfo = get_fileinfo


return M
