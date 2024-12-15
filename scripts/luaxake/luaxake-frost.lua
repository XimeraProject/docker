local M = {}
local pl = require "penlight"
local path = require "pl.path"
local html = require "luaxake-transform-html"
local files = require "luaxake-files"
local log = logging.new("frost")

local json = require("dkjson")

--- save Ximera metadata.json file  (with labels/xourses/...)
--- @param xmmetadata table ximera metadata table
--- @return boolean success 
local function save_as_json(xmmetadata)
    local file = io.open("metadata.json", "w")
  
    if file then
        local contents = json.encode(xmmetadata)
        file:write( contents )
        io.close( file )
        return true
    else
        return false
    end
  end
  
  

local function osExecute(cmd)
    log:debug("Exec: "..cmd)
    local fileHandle = assert(io.popen(cmd .. " 2>&1", 'r'))
    local commandOutput = assert(fileHandle:read('*a'))
    local returnCode = fileHandle:close() and 0 or 1
    commandOutput = string.gsub(commandOutput, "\n$", "")
    log:debug("returns "..returnCode..": "..commandOutput..".")
    return returnCode, commandOutput
end

local function get_output_files(file, extension)
    local result = {}
    for _, entry in ipairs(file.output_files) do
        if entry.extension == extension then --and entry.info.type == targetType then
            table.insert(result, entry)
            log:debug(string.format("Adding %-4s outputfile: %s ", entry.extension, entry.absolute_path))
        end
    end
    return result
end

--- Frosting: create a 'publications' commit-and-tag
---@param file metadata    -- presumably only root-folder really makes sense for 'frosting'
---@return boolean status
---@return string? msg
local function frost(root)
    log:debug("frost")
    
    local tex_files = files.get_tex_files_with_status(root, config.output_formats, config.compilers)
    -- TODO: warn/error/compile if there are to_be_compiled files ?

    local needing_publication = {}
    local all_labels = {}
    local tex_xourses = {}
    for i, tex_file in ipairs(tex_files) do
        log:debug("Output for "..tex_file.absolute_path)
        needing_publication[#needing_publication + 1] = tex_file.relative_path

        local html_files = get_output_files(tex_file, "html")
        
        for i,html_file in ipairs(html_files) do
        -- require 'pl.pretty'.dump(html_file)

            log:debug("Output for "..html_file.absolute_path)
            needing_publication[#needing_publication + 1] = html_file.relative_path

            local html_name = html_file.absolute_path
            local dom, msg = html.load_html(html_name)
            if not dom then 
                log:errorf("No dom for %s (%s). SKIPPING", html_name, msg)
                break
            end
        
            -- get all anchors (from \label)
            html_file.labels = html.get_labels(dom)
            
            -- merge them in a big table, to be added to metadata.json
            for k,v in pairs(html_file.labels) do 
                if all_labels[k] then
                    log:warningf("Label %s already used in %s; ignoring for %s",k, all_labels[k], html_file.relative_path)
                else
                    all_labels[k] = html_file.relative_path
                    log:tracef("Label %s added for %s",k,html_file.relative_path)
                end
            end

            local ass_files = html.get_associated_files(dom, html_file)

            table.move(ass_files, 1, #ass_files, #needing_publication + 1, needing_publication)


            html_file.associated_files = ass_files

            log:info(string.format("Added %4d files for new total of %4d for %s", #ass_files+2,  #needing_publication, html_file.relative_path))
            -- require 'pl.pretty'.dump(to_be_compiled)

            -- Store xourses, they have to be added to metadata.json
            if tex_file.tex_type == "xourse" then
                log:debug("Adding XOURSE "..tex_file.absolute_path.." ("..html_file.title..")")
                tex_xourses[html_file.basename] = { title = html_file.title, abstract = html_file.abstract } 
            end

        end
    end

    -- TODO: add labels; check/fix use of 'github'
    local xmmetadata={
        xakeVersion = "2.1.3",
        labels = all_labels,
        githubexample = {

            owner = "XimeraProject",
            repository = "ximeraExperimental"
        },
        github = {},
        xourses = tex_xourses,
    }


    save_as_json(xmmetadata)
    -- require 'pl.pretty'.dump(tex_xourses)

    needing_publication[#needing_publication + 1] = "metadata.json"

    if path.exists("ximera-downloads") then
        -- needing_publication[#needing_publication + 1] = "ximera-downloads"
        osExecute(" git add -f ximera-dowloads")
    else 
        log:debug("No ximera-downloads folder, and thus no PDF files will be available for download")
    end
    -- require 'pl.pretty'.dump(needing_publication)

    -- 'git add' the files in batches of 10   (risks line-too-long!)
    -- local files_string = table.concat(needing_publication,",")
    -- Execute the git add command

    

-- Recursive function to list all files in a directory
function list_files(path, files)
    files = files or {}
    for file in lfs.dir(path) do
        -- Skip "." and ".." (current and parent directory)
        if file ~= "." and file ~= ".." then
            local full_path = path .. "/" .. file
            local attr = lfs.attributes(full_path)
            
            -- If it's a directory, recurse into it
            if attr.mode == "directory" then
                list_files(full_path,files)
                --table.move(nfiles,1,#nfiles,#files+1,files)
            else
                -- If it's a file, print its path
                -- f:write(full_path.."\n")
                files[#files+1] = full_path
             end
        end
    end
    return files
end

local downloads =  list_files("ximera-downloads")
table.move(downloads, 1, #downloads, #needing_publication + 1, needing_publication)


    local f = io.open(".xmgitindexfiles", "w")

    for _, line in ipairs(needing_publication) do
        log:trace("ADDING "..line)
        f:write(line .. "\n")
    end
    f:close()
    -- Close the process to flush stdin and complete execution
    local proc = io.popen("cat .xmgitindexfiles | git update-index --add  --stdin")
    local output = proc:read("*a")
    local success, reason, exit_code = proc:close()

    if not success then
        log:errorf("git update-index fails with %s (%d)",reason, exit_code)
    else 
        log:debugf("Added %d files:\n%s", #needing_publication,output)
    end

    local _, sourceoid = osExecute("git write-tree")
    if not sourceoid then
        log:error("No sourceid returned by git write-tree")
    end
    log:debug("GOT source "..(sourceoid or ""))

    local _, headid = osExecute("git rev-parse HEAD")
    if not headid then
        log:error("No headid returned by git rev-parse HEAD")
    end


    local ret, commitoid = osExecute("git commit-tree -m Publishedxxx -p "..headid.." "..sourceoid)
    if not commitoid then
        log:error("No commitoid returned by git commit-tree")
    end
    log:debug("GOT commit "..(commitoid or ""))
    
    if logging.show_level <= logging.levels["trace"] then
        log:tracef("Committed files for %s:", commitoid)
        osExecute("git ls-tree -r --name-only "..commitoid)
    end

    local tagName = "publications/"..headid

    result, output = osExecute("git rev-parse "..tagName.." --")


    if result then
        if output == commitoid
        then
            log:status("Tag "..tagName.." already exists")
            return 0
        else
            log:infof("Updating tag %s for %s (was %s)", tagName, commitoid, output)
            result, output = osExecute("git update-ref "..tagName.." "..commitoid)
            return result, output
        end
    else
        log:info("Creating tag "..tagName.." for "..commitoid)
        result, output = osExecute("git tag "..tagName.." "..commitoid)
        if result == 0 then
            log:status("Created "..tagName.." for "..commitoid)
        end
        return result, output
    end
    -- never reach here ...
end

M.get_output_files      = get_output_files
M.frost      = frost

return M
