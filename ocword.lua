-- v1.0
local component = require("component")
local term = require("term")
local io = require("io")
local fs = require("filesystem")
local shell = require("shell")
local event = require("event")
local keyboard = require("keyboard")
local unicode = require("unicode")
local serialization = require("serialization")

local gpu = term.gpu()

local screen = {}
screen.width, screen.height = gpu.getResolution()

-- Config
local Config = {
    pageMaxLines = 20,
    palette = {
        0xFF0000, 0x00FF00, 0x0000FF,
        0xFFFF00, 0x00FFFF, 0xFF00FF,
        0xFFFFFF, 0x000000, 0x808080
    },
    theme = {
        editorBackground = 0xC3C3C3,
        pageBackground = 0xFFFFFF,
        themeColour = 0X969696,
        defaultText = 0x000000
    },
    pageSize = {
        width = 28,
        height = 20
    }
}

-- Editor Object
local Editor = {}

Editor.active = true

Editor.activePageIndex = 1
Editor.scroll = 0

Editor.cursorX = 1
Editor.cursorY = 1

Editor.buffer = {}

Editor.topBarPage = 1

-- Argument handling
local args = { ... }
if #args ~= 1 then
    io.write("Usage: ocword <filename>")
    io.write("File must be of .doc type")
    return
end

if not string.match(args[1], "%.doc$") then
    Editor.filename = shell.resolve(args[1], ".doc")
else
    Editor.filename = shell.resolve(args[1])
end

Editor.file_parentpath = fs.path(Editor.filename)

if fs.exists(Editor.file_parentpath) and not fs.isDirectory(Editor.file_parentpath) then
    io.stderr:write(string.format("Not a directory: %s\n", Editor.file_parentpath))
    return 1
end

Editor.readonly = fs.get(Editor.filename) == nil or fs.get(Editor.filename).isReadOnly()

if fs.isDirectory(Editor.filename) then
  io.stderr:write("file is a directory\n")
  return 1
elseif not fs.exists(Editor.filename) and Editor.readonly then
  io.stderr:write("file system is read only\n")
  return 1
end

-- Buttons
local Buttons = {}

Buttons["exit"] = {
    pos = { x = screen.width - 4, y = 1 },
    size = { w = 3, h = 1},
    press = function ()
        Editor.active = false
        gpu.setBackground(0x000000)
        gpu.setForeground(0xFFFFFF)
        term.clear()
        event.push("ocword_exit")
    end
}

local PaletteButtons = {}

-- Draw
function Redraw()
    term.clear()

    -- Fill entire screen
    gpu.setBackground(Config.theme.editorBackground)
    gpu.fill(1, 1, screen.width, screen.height, " ")
    
    local currentPage = Editor.buffer[Editor.activePageIndex]

    local currentPageX, currentPageY = currentPage:getAxes()
    local cursorScreenY = currentPageY + Editor.cursorY - 1

    for pageNr, page in ipairs(Editor.buffer) do
        local pageX, pageY = page:getAxes()

        if pageY + Config.pageSize.height <= 0 then goto continue end
        if pageY > screen.height then goto continue end
        page:draw(pageX, pageY)

        ::continue::
    end
    
    -- Topbar
    gpu.setBackground(Config.theme.themeColour)
    gpu.fill(1, 1, screen.width, 3, " ")

    gpu.setForeground(Config.theme.defaultText)
    gpu.set(1, 1, "ocword [" .. fs.name(Editor.filename) .. "]")

    gpu.setForeground(0xFF0000)
    gpu.set(screen.width - 4, 1, "[X]")

    for colourIndex, paletteButton in ipairs(PaletteButtons) do
        local colour = paletteButton.colour
        gpu.setBackground(colour)
        gpu.fill(paletteButton.pos.x, paletteButton.pos.y, 2, 1, " ")
    end
    
    gpu.setForeground(Config.theme.defaultText)

    if cursorScreenY < 1 or cursorScreenY > screen.height then
        term.setCursor(1, screen.height)
        term.setCursorBlink(false)
        gpu.setForeground(Config.theme.editorBackground)
    else
        local line = currentPage.buffer[Editor.cursorY]

        term.setCursor(Editor.cursorX + currentPageX, cursorScreenY)  

        term.setCursorBlink(true)
        gpu.setForeground(line and line.colour or Config.theme.defaultText)
    end
end

-- PaletteButtons
for index, colour in ipairs(Config.palette) do
    Buttons[colour] = {
        pos = { x = (index * 3) - 2, y = 3},
        size = { w = 2, h = 1 },
        press = function ()
            local page = Editor.buffer[Editor.activePageIndex]
            if not page.buffer[Editor.cursorY] then return end
            page.buffer[Editor.cursorY].colour = colour

            Redraw()
        end,
        colour = colour
    }

    table.insert(PaletteButtons, index, Buttons[colour])
end


-- Page Object
local Page = {}
Page.__index = Page

function Page:write(char)
    local cursorLine = Editor.cursorY
    local cursorCol = Editor.cursorX

    -- Create line if it doesn't exist
    if not self.buffer[cursorLine] then
        self.buffer[cursorLine] = { str = "", colour = Config.theme.defaultText }
    end

    if self.y == nil then
        local x, y = self:getAxes()
        self.x = x
        self.y = y
    end

    local cursorScreenY = self.y + Editor.cursorY - 1
    if cursorScreenY < 1 then
        -- Cursor is above the screen, scroll up
        Editor.scroll = Editor.scroll - (1 - cursorScreenY) - screen.height / 2
    elseif cursorScreenY > screen.height then
        -- Cursor is below the screen, scroll down
        Editor.scroll = Editor.scroll + (cursorScreenY - screen.height) + screen.height / 2
    end

    for ln=1, cursorLine do
        if not self.buffer[ln] then
            self.buffer[ln] = { str = "", colour = Config.theme.defaultText }
        end
    end

    -- Insert char at cursor position
    local line = self.buffer[cursorLine]
    local before = unicode.sub(line.str, 1, cursorCol - 1)
    local after = unicode.sub(line.str, cursorCol)

    line.str = before .. char .. after
    Editor.cursorX = Editor.cursorX + 1

    -- Check wrap
    if unicode.wlen(line.str) > 26 then
        -- Overflow handling
        local overflowChar = unicode.sub(line.str, -1)
        line.str = unicode.sub(line.str, 1, -2)

        local nextLine = Editor.cursorY + 1

        -- Move cursor
        if Editor.cursorX > 26 then
            Editor.cursorX = 2
            Editor.cursorY = nextLine

            if self.y + Editor.cursorY > screen.height then
                Editor.scroll = Editor.scroll + 2
            end
        end

        -- Push text to next line/page
        self:pushText(nextLine, overflowChar)
    end

    Redraw()
end

function Page:deleteChar()
    local cursorLine = Editor.cursorY
    local cursorCol = Editor.cursorX

    -- If no line exists, move cursor to end of last line
    if not self.buffer[cursorLine] then
        Editor.cursorY = #self.buffer
        Editor.cursorX = #(self.buffer[#self.buffer].str) + 1
        Redraw()
        return
    end

    local line = self.buffer[cursorLine]

    -- If cursor is at the beginning of a line (col 1), merge with the previous line
    if cursorCol <= 1 then
        if cursorLine > 1 then
            local prevLine = self.buffer[cursorLine - 1]
            local currentLine = self.buffer[cursorLine]
            prevLine.str = prevLine.str .. currentLine.str
            currentLine.str = ""
            Editor.cursorY = cursorLine - 1
            Editor.cursorX = #prevLine.str + 1
        else
            if Editor.activePageIndex > 1 then
                local prevPage = Editor.buffer[Editor.activePageIndex - 1]
                local thisPage = self

                local lastLineIndex = #prevPage.buffer
                local lastLine = prevPage.buffer[lastLineIndex]

                lastLine.str = lastLine.str .. thisPage.buffer[1].str
                if unicode.wlen(lastLine.str) > 26 then
                    local before = string.sub(lastLine.str, 1, 26)
                    local after = string.sub(lastLine.str, 27, -1)

                    lastLine.str = before

                    if lastLineIndex < Config.pageMaxLines then
                        self:pushText(lastLineIndex + 1, after)
                    else
                        thisPage:pushText(1, after)
                    end
                else
                    thisPage.buffer[1].str = ""
                end

                local function getBufferLength()
                    local len = 0
                    for _, line in pairs(thisPage.buffer) do
                        if line.str ~= "" then len = len + 1 end
                    end
                    return len
                end

                if getBufferLength() == 0 then
                    table.remove(Editor.buffer, Editor.activePageIndex)
                    Editor.activePageIndex = Editor.activePageIndex - 1
                end

                Editor.cursorY = lastLineIndex
                Editor.cursorX = #lastLine.str + 1
            end
        end
    else
        -- Normal backspace: delete character before cursor
        local before = unicode.sub(line.str, 1, cursorCol - 2)
        local after = unicode.sub(line.str, cursorCol)
        line.str = before .. after
        Editor.cursorX = cursorCol - 1
    end
    Redraw()
end

function Page:enter()
    local cursorLine = Editor.cursorY
    local cursorCol = Editor.cursorX

    -- Split current line at cursor
    local currentLine = self.buffer[cursorLine] or { str = "", colour = Config.theme.defaultText }
    local before = unicode.sub(currentLine.str, 1, cursorCol - 1)
    local after = unicode.sub(currentLine.str, cursorCol)

    currentLine.str = before
    self.buffer[cursorLine] = currentLine

    if cursorLine + 1 > 20 then
        local nextPage = Editor.buffer[self.pageNumber + 1]
        if not nextPage then
            nextPage = Page.new(self.pageNumber + 1)
            table.insert(Editor.buffer, nextPage)
        end

        nextPage:pushNewLine({ str = after, colour = currentLine.colour or Config.theme.defaultText })
        Editor.activePageIndex = self.pageNumber + 1
        Editor.cursorX = 1
        Editor.cursorY = 1
    else
        if #self.buffer + 1 > 20 then
            local nextPage = Editor.buffer[self.pageNumber + 1]
            if not nextPage then
                nextPage = Page.new(self.pageNumber + 1)
                table.insert(Editor.buffer, nextPage)
            end

            nextPage:pushNewLine(self.buffer[#self.buffer])
        end
        table.insert(self.buffer, Editor.cursorY + 1, { str = after, colour = currentLine.colour or Config.theme.defaultText })
        Editor.cursorX = 1
        Editor.cursorY = Editor.cursorY + 1
    end

    Redraw()
end

function Page:pushNewLine(line)
    if #self.buffer + 1 > 20 then
        local nextPage = Editor.buffer[self.pageNumber + 1]
        nextPage:pushNewLine(self.buffer[#self.buffer])

        table.remove(self.buffer, #self.buffer)
        table.insert(self.buffer, 1, line)
    else
        table.insert(self.buffer, 1, line)
    end
end

function Page:pushText(lineNumber, char)
    if lineNumber <= 20 then
        if not self.buffer[lineNumber] then
            self.buffer[lineNumber] = { str = "", colour = Config.theme.defaultText }
        end
        self.buffer[lineNumber].str = char .. self.buffer[lineNumber].str
        if #self.buffer[lineNumber].str > 26 then
            local overflowChar = unicode.sub(self.buffer[lineNumber].str, -1)
            self.buffer[lineNumber].str = unicode.sub(self.buffer[lineNumber].str, 1, -2)

            self:pushText(lineNumber + 1, overflowChar)
        end
    else
        -- Push to next page
        local nextPageIndex = self.pageNumber + 1
        local nextPage = Editor.buffer[nextPageIndex]

        if not nextPage then
            nextPage = Page.new(nextPageIndex)
            table.insert(Editor.buffer, nextPage)
        end

        if Editor.cursorY > 20 then
            Editor.cursorY = 1
            Editor.cursorX = 2  -- After the pushed char
            Editor.activePageIndex = nextPageIndex
        end

        nextPage:pushText(1, char)
    end
end

function Page:getAxes()
    local posX = (screen.width / 2) - (Config.pageSize.width / 2)
    local posY = (screen.height / 5) + ((Config.pageSize.height + 2) * (self.pageNumber - 1))
    posY = posY - Editor.scroll

    return posX, posY
end

function Page:isInBounds(x, y)
    if not (self.x and self.y) then return false end
    local isInX = (x >= self.x + 1) and (x < self.x + Config.pageSize.width - 1)
    local isInY = (y >= self.y) and (y < self.y + Config.pageSize.height)

    return isInX and isInY
end

function Page:draw(x, y)
    gpu.setBackground(Config.theme.pageBackground)
    gpu.fill(x, y, Config.pageSize.width, Config.pageSize.height, " ")

    self.x = x
    self.y = y

    for lineNr, line in ipairs(self.buffer) do
        gpu.setForeground(line.colour or Config.theme.defaultText)
        gpu.setBackground(Config.theme.pageBackground)

        local lineX = x + 1
        local lineY = y + lineNr - 1

        gpu.set(lineX, lineY, line.str)
    end
end

function Page.new(pageNumber)
    local self = {}

    self.pageNumber = pageNumber or #Editor.buffer + 1
    self.buffer = {}

    if self.pageNumber < #Editor.buffer + 1 then
        for otherPageNr, otherPage in pairs(Editor.buffer) do
            if otherPageNr >= self.pageNumber then
                otherPage.pageNumber = otherPage.pageNumber + 1
            end
        end
    end

    setmetatable(self, Page)

    return self
end

-- Keybinds
local Keybinds = {}

Keybinds["newPage"] = {
    keys = { keyboard.keys.lcontrol, keyboard.keys.space },
    callback = function ()
        local newPage = Page.new(Editor.activePageIndex + 1)
        table.insert(Editor.buffer, newPage)

        Editor.activePageIndex = newPage.pageNumber
        Editor.cursorX = 1
        Editor.cursorY = 1

        Redraw()
    end
}

Keybinds["print"] = {
    keys = { keyboard.keys.lcontrol, keyboard.keys.p },
    callback = function ()
        local op = component.openprinter

        for _, page in pairs(Editor.buffer) do
            op.setTitle(fs.name(string.sub(Editor.filename, 1, -5)) .. " ["..page.pageNumber.."]")
            for _, line in pairs(page.buffer) do
                op.writeln(line.str, line.colour)
            end
            op.print()
        end
    end
}

Keybinds["save"] = {
    keys = { keyboard.keys.lcontrol, keyboard.keys.s },
    callback = function ()
        if Editor.readonly then return end
        local convBuffer = {}

        for pageNr, page in pairs(Editor.buffer) do
            local pageTbl = page.buffer
            table.insert(convBuffer, pageNr, pageTbl)
        end

        local convBufferStr = serialization.serialize(convBuffer)

        
        local new = not fs.exists(Editor.filename)
        if new then
            if not fs.exists(Editor.file_parentpath) then
                fs.makeDirectory(Editor.file_parentpath)
            end
        else
            local backup = Editor.filename .. "~"
            
            for i = 1, math.huge do
                if not fs.exists(backup) then
                    break
                end
                backup = Editor.filename .. "~" .. i
            end
            fs.copy(Editor.filename, backup)
        end
        local file = io.open(Editor.filename, "w")
        file:write(convBufferStr)
    end
}

Keybinds["left"] = {
    keys = { keyboard.keys.left },
    callback = function ()
        local currentPage = Editor.buffer[Editor.activePageIndex]
        if Editor.cursorX - 1 < 1 then
            if Editor.cursorY - 1 < 1 then
                if Editor.activePageIndex ~= 1 then
                    local prevPage = Editor.buffer[Editor.activePageIndex - 1]
                    Editor.cursorY = #prevPage.buffer
                    Editor.cursorX = unicode.wlen(prevPage.buffer[Editor.cursorY].str) + 1

                    Editor.activePageIndex = Editor.activePageIndex - 1
                end
            else
                Editor.cursorX = currentPage.buffer[Editor.cursorY - 1] and unicode.wlen(currentPage.buffer[Editor.cursorY - 1].str) + 1 or 1
                Editor.cursorY = Editor.cursorY - 1
            end
        else
            Editor.cursorX = Editor.cursorX - 1
        end
        Redraw()
    end
}

Keybinds["right"] = {
    keys = { keyboard.keys.right },
    callback = function ()
        local currentPage = Editor.buffer[Editor.activePageIndex]
        if Editor.cursorX + 1 > (currentPage.buffer[Editor.cursorY] and unicode.wlen(currentPage.buffer[Editor.cursorY].str) or 1) then
            if Editor.cursorY + 1 > Config.pageMaxLines then
                if Editor.activePageIndex ~= #Editor.buffer then
                    Editor.cursorY = 1
                    Editor.cursorX = 1

                    Editor.activePageIndex = Editor.activePageIndex + 1
                end
            else
                Editor.cursorX = 1
                Editor.cursorY = Editor.cursorY + 1
            end
        else
            Editor.cursorX = math.min(Editor.cursorX + 1, currentPage.buffer[Editor.cursorY] and unicode.wlen(currentPage.buffer[Editor.cursorY].str) + 1 or 1)
        end
        Redraw()
    end
}

function GetBind(code)
    local keyboardAddress = term.keyboard()

    local function checkBind(bind)
        local needsCtrl, needsAlt = false, false
        local ctrl, alt, key = false, false, false

        for _, bindKey in ipairs(bind.keys) do
            if bindKey == keyboard.keys.lcontrol then
                needsCtrl = true
                if keyboard.isControlDown(keyboardAddress) then
                    ctrl = true
                end
            elseif bindKey == code then
                key = true
            end
        end

        if needsAlt and needsCtrl then
            return ctrl and alt and key
        elseif needsCtrl then
            return ctrl and key
        elseif needsAlt then
            return alt and key
        else
            return key
        end
    end

    for _, bind in pairs(Keybinds) do
        if checkBind(bind) then
            return bind
        end
    end
    return nil
end

-- Event handling
local Events = {}

Events["scroll"] = function (_, _, _, direction)
    Editor.scroll = Editor.scroll - (direction * 2)
    Redraw()
end

Events["key_down"] = function (_, key, code)
    local page = Editor.buffer[Editor.activePageIndex]
    if key == 8 then
        page:deleteChar()
    elseif key == 13 then
        page:enter()
    else
        local bind = GetBind(code)
        if bind ~= nil then
            bind.callback()
        else
            -- normal character
            if key ~= 0 or Editor.readonly then
                page:write(unicode.char(key))
            end
        end
    end
end

Events["touch"] = function (_, x, y)
    local function checkIsInPage()
        for _, page in pairs(Editor.buffer) do
            if page:isInBounds(x, y) then return page end
        end
        return nil
    end

    local page = checkIsInPage()
    if page then
        local cursorX = x - (page.x)
        local cursorY = y - (page.y - 1)

        Editor.cursorX = math.min(cursorX, page.buffer[cursorY] and unicode.wlen(page.buffer[cursorY].str) + 1 or 1)
        Editor.cursorY = cursorY

        Editor.activePageIndex = page.pageNumber
        Redraw()
    else
        for _, button in pairs(Buttons) do
            local isInX = (x >= button.pos.x) and (x <= button.pos.x + button.size.w)
            local isInY = (y >= button.pos.y) and (y <= button.pos.y + button.size.h)

            if isInX and isInY then
                button.press()
                break
            end
        end
    end
end

do
    Editor.buffer = {}

    local file = io.open(Editor.filename)
    if file then
        local decoded = serialization.unserialize(file:read("a"))
        file:close()
        if decoded then
            for pageNr, page in ipairs(decoded) do
                local pageObj = Page.new(pageNr)
                pageObj.buffer = page

                table.insert(Editor.buffer, pageNr, pageObj)
            end
        else
            io.stderr:write("Failed to load file buffer.")
            return -1
        end
    else
        Editor.buffer = { Page.new(1) }
    end

    Redraw()
    while Editor.active do
        local event, address, arg1, arg2, arg3, arg4 = term.pull()
        
        if event == "ocword_exit" then
            Editor.active = false
            break
        end

        if Events[event] ~= nil then
            Events[event](address, arg1, arg2, arg3, arg4)
        end
    end
end
