local M = {}
local pl = require "penlight"
local path = require "pl.path"
local html_transform = require "luaxake-transform-html"
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
    log:info("Exec: "..cmd)
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
            local dom, msg = html_transform.load_html(html_name)
            if not dom then return false, msg end
        
            local ass_files = html_transform.get_associated_files(dom, html_file)

            table.move(ass_files, 1, #ass_files, #needing_publication + 1, needing_publication)


            html_file.associated_files = ass_files

            log:info(string.format("Added %4d files for %s, total now %4d", #ass_files+2, html_file.relative_path, #needing_publication))
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
        labels = {},
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

    if path.exists("ximera-download") then
        needing_publication[#needing_publication + 1] = "ximera-downloads"
    else 
        log:debug("No ximera-download folder, and thus no PDF files will be available for download")
    end
    -- require 'pl.pretty'.dump(needing_publication)

    -- 'git add' the files in batches of 10   (risks line-too-long!)
    -- local files_string = table.concat(needing_publication,",")
    -- Execute the git add command

    local group_size=10
    for i = 1, #needing_publication, group_size do
        -- Print the current group
        -- log:debug("Group starting at index " .. i .. ":")
        
        local  next = table.concat(table.move(needing_publication,i, math.min(i + group_size - 1, #needing_publication),1,{}),' ')
        local command = "git add -f "  .. next
        local  exit_code, result = osExecute(command)

        -- Check the result and exit code
        if exit_code == 0 then
            log:debug("Files added successfully: "..result)
        else
            log:error("Error adding files. Exit code "..exit_code..": "..(result or ""))
        end
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

    local tagName = "publications/"..headid

    log:info("Creating tag "..tagName.." for "..commitoid)

    result, output = osExecute("git tag -l "..tagName)

    if output == tagName
    then
        log:status("Tag "..tagName.." already exists")
        return 0
    else
        result, output = osExecute("git tag "..tagName.." "..commitoid)
        if result == 0 then
            log:status("Created "..tagName.." for "..commitoid)
        end
        return result
    end
    -- never reach here ...
end

M.frost      = frost

return M
