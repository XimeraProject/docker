local M = {}
local pl = require "penlight"
local graph = require "luaxake-graph"
local log = logging.new("files")
local lfs = require "lfs"

local path = pl.path
local abspath = pl.path.abspath
local tablex = pl.tablex

GLOB_files = {}     -- global variable with all fileinfo collected with get_files  (caching...)



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
local function get_fileinfo(input_path)

  -- caching
  if GLOB_files[input_path] then
    log:tracef("Getting cached fileinfo for %s", input_path)
    return GLOB_files[input_path]
  end
  
  log:tracef("Getting fileinfo for %s", input_path)

  -- if root_folder and string.match(input_path, "^"..root_folder) then
  --   input_path = input_path:gsub("^"..root_folder, "")
  -- end

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

  GLOB_files[fileinfo.relative_path] = fileinfo

  return fileinfo
end


--- get fileinfo for all files in a directory and it's subdirectories
--- @param dir string path to the directory
--- @param files? table retrieved files
--- @return fileinfo[]
local function get_files(dir)
  --dir = dir:gsub("/$", "")    -- remove potential trailing '/'
  dir = dir:gsub("^./", "")    -- remove potential leading './'     -- it confuses skippingb hidden .xxx files/folders
  dir = path.normpath(dir)
  local all_filenames = {}

  if path.isfile(dir)  then
    all_filenames = { dir }
    log:tracef("get_files: considering %s", dir)
  else
    all_filenames = pl.dir.getallfiles(dir)
    log:tracef("get_files: considering %d files (for %s)", #all_filenames, dir)
  end


  local files = {}

  for _, filename in ipairs(all_filenames) do
    -- ext = path.extension(filename)

    -- local basename = filename:match(".*/(.*)$") or filename  -- Extract filename from path
    if filename:match("/%.") then  -- ignore every file/folder starting with a . (ie, containing xxx/.yyy )
      -- log:tracef("get_files skips %s", filename)
      goto next_file
    end

    ext = filename:match("%.([^%.]+)$")

    -- log:tracef("get_files adding %s (%s)", filename, ext)
    if config.keep_extensions[ext] then
      log:tracef("get_files adding %s", filename)

      finfo = get_fileinfo(filename)
      files[finfo.relative_path] = finfo
    end

    ::next_file::
  end

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

--- get TeX documentclass ( and thus can it be compiled standalone, is it a ximera or a xourse)
--- @param file fileinfo the tested TeX file
--- @param linecount number maximum number of lines that should be tested to find \documentclass
--- @return string tex_type the documentclass, or 'no-document'
local function get_tex_type(file, linecount)
  -- we assume that the main TeX file contains \documentclass near beginning of the file 
  linecount = linecount or 30 -- number of lines that will be read
  local filename = file.absolute_path
  local line_no = 0

  local f, msg = io.open(filename, "r")
  if not f then
    log:warningf("Could not open file %s: %s",filename, msg)
    return 'no-document'
  end

  for line in io.lines(filename) do    -- TODO: test existence of file!
    line_no = line_no + 1
    if line_no > linecount then 
      return 'no-document'
    end
    -- TODO: quid comments ???
    local class_name = line:match("\\documentclass%s*%[[^]]*%]%s*{([^}]+)}")
                    or line:match("\\documentclass%s*{([^}]+)}")
    if class_name then
      -- log:trace("Document class: " .. class_name)
      return class_name
    end
  end
  return 'no-document'
end

--- Detect if the output file needs recompilation
---@param tex fileinfo metadata of the main TeX file to be compiled
---@param outfile fileinfo metadata of the output file
---@return boolean
local function needs_compiling(tex, outfile)
  -- if the output file doesn't exist, it needs recompilation
  log:tracef("Does %s need compilation? %s",outfile.relative_path, outfile.exists and "It exists." or "It doesn't exist.")
  if not outfile.exists then return true end
  -- test if the output file is older if the main file or any dependency
  local status = tex.modified > outfile.modified
  if status then 
    log:debugf("TeX file %s has changed since compilation of %s",tex.relative_path, outfile.relative_path)
  end

  if not tex.depends_on_files  then
    log:warningf("File %s does not depend on any files ...?")
  else
  for filename, subfile in pairs(tex.depends_on_files or {}) do
    log:tracef("Check modified of subfile %s", subfile.relative_path)
    if not subfile or not subfile.relative_path or not subfile.modified then
        log:warning("Incomplete data for dependency of %s",tex.relative_path)
        pl.pretty.dump(subfile)
    end
    if subfile.modified > outfile.modified then
      log:tracef("Dependent file %s has changed since compilation of %s",subfile.relative_path,  outfile.relative_path)
      status = status or subfile.modified > outfile.modified
    end
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
  local extra_tex_files = {}

  for _, dep in ipairs(config.default_dependencies or {}) do
    fileinfo.depends_on_files[dep] = get_fileinfo(dep)
  end

  local f, msg = io.open(filename, "r")
  if not f then
    log:errorf("Could not open file %s: %s",filename, msg)
    return {}
  end

    local content = f:read("*a")
    f:close()
    -- remove all comments   (otherwise also commented commands would be processed!)
    -- content = content:gsub("([^\\])%%.-\n", "%1\n")
    content = content:gsub("%%[^\n]*", "")
    -- loop over all LaTeX commands with arguments
    for command, argument in content:gmatch("\\(%w+)%s*{([^%}]+)}") do
      -- add dependency if the current command is \input like
      local metadata = nil    -- should be fileinfo ...
      local included_file = nil
      local wanted_extension = nil
      if command == "dependsonpdf" then
        -- hack to include PDF (or SVG) eg of cheatsheets (that can/should not converted to HTML)
        included_file = fileinfo.relative_path:gsub(".tex","_pdf.tex")
        wanted_extension = "pdf"
      elseif config.input_commands[command] then
        -- log:tracef("Consider %s{%s}", command, argument)
        included_file = path.normpath(current_dir.."/"..argument)     -- remove potential ../ 
        wanted_extension = "html"    -- because the html will/might be read to get 
        if not path.isfile(included_file) then
          if not path.isfile(included_file..".tex") then
            if not path.isfile(included_file..".sty") then
              log:warningf("Included file %s not found", included_file)
            else
              included_file = included_file..".sty"
            end
          else
            included_file = included_file..".tex"
          end
        end
        log:debugf("Consider included file %s (rel %s)", included_file, path.relpath(included_file, current_dir))
        included_file = path.relpath(included_file, GLOB_root_dir)      -- make relative path 

      else
        -- log:tracef("Nothing to process for command %s", command)   -- would log all commands in the .tex file .... !!!
      end

      if included_file then

          local fileinfo = get_fileinfo(included_file)

          log:tracef("Getting tex_file_with_status for %s", included_file)
          local extra_tex = update_status_tex_file(fileinfo, {wanted_extension}, {wanted_extension} )
          for fname, finfo in pairs(extra_tex) do
            metadata = finfo     --- BADBAD: only one 'dependency' properly supported here, but included_file migth itself depend on stuff!!!
            log:tracef("Adding to tex_fileinfo:  %s (dependend file from %s)", fname, fileinfo.relative_path)
            extra_tex_files[fname] = finfo
          end
        end 
        if metadata then
          if metadata.exists then
            log:debugf("File %s depends on %s", fileinfo.relative_path, metadata.relative_path)
            fileinfo.depends_on_files[metadata.absolute_path] = metadata
            fileinfo.depends_on_files[metadata.relative_path] = metadata
          else
            log:warningf("File %s depends on non-existing file %s (%s); NOT ADDED TO DEPENDENT FILES", fileinfo.relative_path, metadata.relative_path, metadata.absolute_path)
          end
      end  -- included_file
      -- next command ...
    end
  --log:debugf("tex_dependencies found %d dependencies for %s", tablex.size(fileinfo.depends_on_files), filename)
  log:tracef("%s has dependencies %s", filename, table.concat(fileinfo.depends_on_files,', '))
  return extra_tex_files
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
    local html_file = get_fileinfo(metadata.relative_path:gsub("tex$", extension))     -- could also be a pdf_file ...!!!
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
    log:debugf("%-12s %18s: %s",extension,  status and 'COMPILE' or 'OK', html_file.absolute_path)
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
    log:tracef("Get used = %s (%s)",current_name, tablex.keys(metadata.depends_on_files))
    for filename, child in pairs(metadata.depends_on_files or {}) do
    -- for _, child in ipairs(metadata.dependecies or {}) do
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
function update_status_tex_file(metadata, output_formats, compilers)
    log:tracef("update_status_tex_file %s (for output_formats=%s and compilers=%s)", metadata.relative_path, table.concat(output_formats,', '), table.concat(compilers,', '))

    local tex_fileinfos = {}
    metadata.tex_type = get_tex_type(metadata, config.documentclass_lines)     -- ximera, xourse, no-document 
    -- update metadata with a list of included TeX files, and store it in tex_fileinfos

    tex_fileinfos[metadata.relative_path] = metadata

    if metadata.tex_type == "no-document" then
      log:tracef("%s has no documentclass; skipping dependencies/output etc", metadata.relative_path)
    else

      for fname, finfo in pairs(update_depends_on_files(metadata)) do
        log:tracef("Adding to tex_fileinfo:  %s (dependend file of %s)", fname, metadata.relative_path)
        tex_fileinfos[fname] = finfo
      end
      -- check for the need compilation
      local status, output_files = check_output_files(metadata, output_formats, compilers)
      metadata.needs_compilation = status
      metadata.output_files = output_files
      -- try to find the TeX4ht .cfg file
      -- to speed things up, we will find it only for files that needs a compilation
      if metadata.needs_compilation then
        -- search in the current work dir first, then in  the directory of the TeX file, and project root
        -- TODO: check use of 'config.dir' !!!
        -- metadata.config_file = find_config(config.config_file, {lfs.currentdir(), metadata.absolute_dir, abspath(dir)})
        metadata.config_file = find_config(config.config_file, {lfs.currentdir(), metadata.absolute_dir, abspath(dir or ".")})
        if metadata.config_file ~= config.config_file then log:debug("Use config file: " .. metadata.config_file) end
      end
      if status then
        log:infof("%-12s %18s: %s", metadata.extension,  status and 'NEEDS_COMPILATION' or 'OK', metadata.relative_path)
      else
        log:debugf("%-12s %18s: %s", metadata.extension,  status and 'NEEDS_COMPILATION' or 'OK', metadata.relative_path)
      end
    end
    return tex_fileinfos
end

--- find TeX files that needs to be compiled in the directory tree
--- @param dir string root directory where we should find TeX files
--- @return metadata[] tex_files list of all TeX files found in the directory tree
function get_tex_files_with_status(dir, output_formats, compilers)
  log:debugf("Getting tex files in %s (for output_formats=%s and compilers=%s)", dir, table.concat(output_formats,', '), table.concat(compilers,', '))
  local files = get_files(dir, {})
  local tex_files = filter_tex_files(files)

  local tex_fileinfos = {}
  -- now check which output files needs a compilation
  for _, metadata in ipairs(tex_files) do
    for fname, finfo in pairs(update_status_tex_file(metadata, output_formats, compilers)) do
      log:tracef("Adding to tex_fileinfo:  %s", fname)
      tex_fileinfos[fname] = finfo
    end
    
  end

  -- -- SKIPPED: create ordered list of files that needs to be compiled
  return tex_fileinfos
end

M.get_tex_files_with_status = get_tex_files_with_status
M.sort_dependencies = sort_dependencies
M.get_fileinfo = get_fileinfo


return M
