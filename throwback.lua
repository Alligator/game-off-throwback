-- constants
PI = 3.14159
SPR_ROAD = 0
SPR_FINISH = 8
SPR_0 = 224
ROAD_HEIGHT = 58
INIT_TIMER = 60

SPR_MID_BG = 64
COL_SKY = 12
COL_GROUND = 3
COL_TEXT = 9
COL_TEXT_FLASH = 7

SEG_RIGHT = 1
SEG_STRAIGHT = 0
SEG_LEFT = -1

-- uh oh it's a state machine
STATE_DRIVING = 0
STATE_FINISHED = 1
STATE_NOT_STARTED = 2
STATE_GAME_OVER = 3

gameState = STATE_NOT_STARTED
frame = 0
driveTextCounter = 0

car = {
    maxSpeed=80,
    maxAccel=0.5,
    maxTurnAccel = 0.25,
    brakeAccel=-1.5,

    -- current state
    speed=0,
    accel=0,
    prevAccel=nil,
    pos=1,
    xpos=56,
    direction=0, -- -1 left, 1 right
    accelerating=false,
    braking=false,
    curSeg=nil,
    paletteSwap={},

    update=function(self)
        -- accel
        if self.braking then
            self.prevAccel = (self.prevAccel == nil and self.accel or self.prevAccel)
            self.accel = self.brakeAccel
        else
            if self.prevAccel != nil then
                self.accel = self.prevAccel
                self.prevAccel = nil
            end

            if self.accelerating then
                self.accel += 0.05
            else
                self.accel = -self.maxAccel
            end
        end

        if self.direction != 0 then
            self.xpos += self.direction * 2
            self.accel = min(self.accel, self.maxTurnAccel)
        end

        if self.accel > self.maxAccel then
            self.accel = self.maxAccel
        end

        -- speed
        if self.speed >= 0 then
            self.speed += self.accel
            if self.speed < 0 then self.speed = 0 end
            if self.speed > self.maxSpeed then self.speed = self.maxSpeed end
            self.pos += self.speed / 20
        end

        if self.speed == 0 then
            self.accel = 0
        end

        if self.curSeg != nil then
            self.xpos += -self.curSeg.seg.dir * (self.speed / self.maxSpeed) * 2
        end

        -- off track
        if self.xpos < 0 or self.xpos > 128 then
            if self.speed > self.maxSpeed/4 then
                self.accel = -self.maxAccel
            end

            self.xpos = max(min(self.xpos, 152), -42)
        end
    end
}

updateq = {}
debugq = {}

eventFsm = nil
timer = 0

function _init()
    cls()
end

function _draw()
    cls()

    drawBackground()
    if gameState == STATE_NOT_STARTED then
        drawRoad()
        drawCar()
        drawAttract()
    elseif gameState == STATE_DRIVING then
        -- sfx(0, 0)
        drawRoad()
        drawCar()

        if driveTextCounter < 100 then
            drawDriveText()
            driveTextCounter += 1
        end

        if eventFsm != nil then
            eventFsm.draw()
        end
        drawTimer()
    elseif gameState == STATE_GAME_OVER then
        -- rectfill(0, 0, 128, 128, 13)
        drawRoad()
        drawCar()
        drawGameOverText()
    else
        sfx(-1, 0)
        drawFinishText()
    end

    local offset = 0
    for item in all(debugq) do
        print(item, 0, offset)
        offset += 8
    end
    debugq = {}

    frame += 1
end

function _update()
    car.curSeg = getSeg(track, car.pos)

    if gameState == STATE_NOT_STARTED then
        updateAttract()
    elseif gameState == STATE_DRIVING then
        if eventFsm == nil then
            eventFsm = makeEventFsm()
        end
        updateTimer()
        updateCar()
        eventFsm.update()

        -- generate more track if we're near the end
        if car.curSeg and car.curSeg.seg == track[#track - 1] then
            local newTrack = generateTrack(10)
            local offset = #track
            track[#track].isFinish = false
            for i = 1, #newTrack do
                track[offset + i] = newTrack[i]
            end
        end

    elseif gameState == STATE_FINISHED then
        car.accel = 0
        car.speed = 0
    end

    for item in all(updateq) do
        item.update(item)
    end

    updateq = {}
end

function updateTimer()
    -- just gonna be lazy and count on 30 fps updates
    timer -= 1/30
    if timer <= 0 then
        gameState = STATE_GAME_OVER
    end
end

function updateAttract()
    if btn(4) then
        gameState = STATE_DRIVING
        timer = INIT_TIMER
    end
end

function updateCar()
    car.accelerating = btn(4)
    car.braking = btn(5)

    car.direction = 0
    if btn(0) then
        car.direction = -1
    end
    if btn(1) then
        car.direction = 1
    end

    if car.curSeg == nil or car.curSeg.seg.isFinish then
        gameState = STATE_FINISHED
    end

    rpm = (car.speed % (car.maxSpeed/3 + 1)) + car.speed / 5
    poke(0x3200, bor(rpm * 0.45, 0x40))
    poke(0x3200 + 1, 0x7)
    poke(0x3200 + 2, bor(rpm * 0.65, 0xc0))
    poke(0x3200 + 3, 0x4)

    add(updateq, car)
end

function drawRoad()
    local curSeg = car.curSeg
    -- if curSeg != nil then
    --     add(debugq, 'cs: '.. curSeg.seg.id .. ', ' .. curSeg.seg.length .. ', ' .. curSeg.seg.dir)
    -- end

    for y = 128 - ROAD_HEIGHT, 128 do
        local z = abs(-64 / (y - 64))
        local scale = 1/z
        local width = 128 * scale
        local skew = (64 - (car.xpos + 8)) * scale
        local margin = (128 - width) / 2
        local texCoord = (z * 8 + car.pos) % 8

        local curveOffset = 0
        if curSeg != nil and curSeg.seg.dir != SEG_STRAIGHT then
            local curveScale = 1 - abs((curSeg.segPos - (curSeg.seg.length / 2)) / (curSeg.seg.length / 2))
            local distScale = 1 - ((y - (128 - ROAD_HEIGHT)) / ROAD_HEIGHT)
            curveOffset = sin(-curSeg.seg.dir * curveScale / 4 * distScale / (scale * 16)) * distScale * 25
        end

        local ySeg = getSeg(track, car.pos + z * 7) -- i don't know why 7 works here
        if ySeg != nil and ySeg.seg.isFinish then
            palt(0, false)
            sspr(SPR_FINISH, texCoord, 8, 1, margin + skew + curveOffset, y, width/2 + 1, 1)
            sspr(SPR_FINISH, texCoord, 8, 1, margin + width/2 + skew + curveOffset, y, width/2, 1)
            palt()
        else
            sspr(SPR_ROAD, texCoord, 8, 1, margin + skew + curveOffset, y, width/2 + 1, 1)
            sspr(SPR_ROAD, texCoord, 8, 1, margin + width/2 + skew + curveOffset, y, width/2, 1, true)
        end

        for name in all(curSeg.seg.hazards) do
            local density = 32
            local hazard = HAZARDS[name]
            local proj = car.pos + z * 8
            local pproj = car.pos + (abs(-64 / (y - 63))) * 8
            local nproj = car.pos + (abs(-64 / (y - 65))) * 8
            if proj % density < pproj %density and proj % density < nproj % density then
                local xpos1 = (width/2) + 64
                local xpos2 = (width/2) - 56
                local height = 64 * scale
                sspr(8, 32, 8, 32, xpos1 + skew + curveOffset, y-height, 8, height)
                sspr(8, 32, 8, 32, (skew + curveOffset) - xpos2, y-height, 8, height, true)
            end

            -- if flr(h.pos) == flr(ySeg) then
            --     sspr(hazard.sx, hazard.sx, hazard.width, hazard.height, 132, y)
            -- end
        end

        pal()
    end
end

function drawCar()
    local sprX = 32
    local width = 32
    local height = 24
    local split = 4
    local y = 124 - height

    if car.xpos < -16 or car.xpos > 128 then
        if car.speed > 0 and frame % 3 == 0 then
            y += 1
        end
    end

    if car.braking then
        pal(2, 8, 0)
    end

    -- TODO fix duplicate palaetteSwap stuff

    if car.direction != 0 then
        local splitWidth = width/split

        pal(7, 4, 0) -- white
        pal(15, 4, 0) -- brown
        pal(8, 4, 0) -- red
        pal(12, 4, 0) -- blue
        sspr(sprX, 8, width, height, 64-width/2 + car.direction, y)
        pal()

        for k, v in pairs(car.paletteSwap) do
            pal(k, v)
        end

        for i = 0, split do
            local sliceX = i * splitWidth
            local offset = i * car.direction
            if car.direction == 1 then
                offset += 1
            end
            sspr(
                sprX + sliceX, 8,
                splitWidth, height,
                64 - (width/2) + sliceX, y + (offset - (car.direction * split/2))
            )
        end
        -- sspr(sprX, 8, width/2, height, 64-width/2, 128-height - car.direction)
        -- sspr(sprX + (width/2), 8, width/2, height, 64, 128-height + car.direction)
    else
        for k, v in pairs(car.paletteSwap) do
            pal(k, v)
        end
        sspr(sprX, 8, width, height, 64-width/2, y)
    end
    pal()

    car.paletteSwap={}
end

function drawTimer()
    -- tiomer is always 2 wide, 0 padded if < 10
    local startx = 53
    local d1 = flr(timer / 10)
    local d2 = flr(timer % 10)
    spr(SPR_0 + d1, startx, 2)
    spr(SPR_0 + d2, startx + 8, 2)
end

function drawAttract()
    printShadowed('press z to start', 64, 42, 9)
    printShadowed('Z: ACCELERATE X: BRAKE', 64, 50, 9)
end

function drawBackground()
    rectfill(0, 0, 128, 56, COL_SKY)
    rectfill(0, 72, 128, 128, COL_GROUND)
    sspr(0, 32, 8, 16, 0, 56, 128, 16)
    -- spr(SPR_MID_BG, 0, 61, 128, 8)
end

function drawFinishText()
    local width = 32
    local height = 14
    wigglyTiledSpr(8, 0, 56 - width/2, 56 - height/2, width + 16, height * 2)
    wigglySspr(0, 96, width, height, 64 - width/2, 64 - height/2)
end

function drawDriveText()
    local width = 36
    local height = 10
    wigglySspr(38, 96, width, height, 64 - width/2, 32)
end

function drawGameOverText()
    local width = 100
    local height = 15
    local y = 38 - height/2
    pal(7, 10)
    wigglySspr(0, 64, width, height, 64 - width/2, y - height - 1)
    pal(7, 9)
    wigglySspr(0, 64, width, height, 64 - width/2, y)
    pal(7, 8)
    wigglySspr(0, 64, width, height, 64 - width/2, y + height + 1)
    pal()

    local miles = flr(car.pos / 100) / 10
    printShadowed('you drove ' .. miles .. ' MILES', 64, 76, COL_TEXT)
    printShadowed('good job!!', 64, 86, getFlashingCol())
    -- function printShadowed(str, x, y, col)
end

function wigglyTiledSpr(sx, sy, dx, dy, width, height)
    local sliceWidth = 4
    local slices = flr(width/sliceWidth)
    for i = 0, slices do
        local yOffset = sin(i / slices + (-frame/16)) * 2

        pal()
        if yOffset < -1 then
            pal(7 ,6)
        end

        for y = 0, height, 8 do
            sspr(sx, sy,
                sliceWidth, 8,
                dx + (i * sliceWidth), dy + yOffset + y)
        end
    end
end

function wigglySspr(sx, sy, sw, sh, dx, dy)
    local sliceWidth = 4
    local slices = flr(sw/sliceWidth)
    for i = 0, slices do
        local yOffset = sin(i / slices + (-frame/16)) * 2
        sspr(sx + i * sliceWidth, sy,
            sliceWidth, sh,
            dx + (i * sliceWidth), dy + yOffset)
    end
end

function generateTrack(segCount)
    -- local segCount = 10 + rnd(10)
    local track = {}
    for i = 1, segCount do
        -- don't repeat the same anything twice in a row
        local newSeg
        if #track == 0 then
            newSeg = createSeg(i, 100 + flr(rnd(100)), SEG_STRAIGHT)
        else
            local prevSeg = track[#track]
            -- prefer curve if straight, prefer straight if curve
            local shouldChangeCurve = 75 > rnd(100)
            local nextDir = prevSeg.dir
            if shouldChangeCurve then
                if prevSeg.dir != SEG_STRAIGHT then
                    nextDir = 0
                else
                    local r = rnd(100)
                    nextDir = (r <= 50 and SEG_LEFT or SEG_RIGHT)
                end
            end
            newSeg = createSeg(i, 100 + flr(rnd(250)), nextDir)
        end
        add(track, newSeg)
    end
    add(track, createSeg(segCount + 1, 2, 0))
    track[#track].isFinish = true
    return addHazards(track)
end

-- for real why is lua so bad
HAZARD_NAMES = {'lamp'}
HAZARDS = {
    lamp = {
        sx = 8,
        sy = 32,
        width = 8,
        height = 32
    }
}

function addHazards(track)
    for seg in all(track) do
        local amount = flr(rnd(seg.length/10))
        local name = HAZARD_NAMES[flr(rnd(#HAZARD_NAMES)) + 1]
        -- printTable({ amount=amount, name=name }, printh)
        seg.hazards = { name }
        -- for i = 1, amount do
        --     add(seg.hazards, { name = name, pos = (seg.length/amount) * i })
        -- end
    end
    return track
end

function createSeg(id, length, direction)
    return {
        id=id,
        length=length,
        dir=direction,
        hazards={},
    }
end

function getSeg(track, pos)
    local sum = 0
    for seg in all(track) do
        if pos > sum and pos < (sum + seg.length) then
            return {
                seg=seg,
                segPos=pos - sum,
                totalPos=(sum + seg.length) - pos
            }
        end
        sum += seg.length
    end
end

-- TODO give states real names
EVT_STATE_IDLE = 1
EVT_STATE_1 = 2
EVT_STATE_SUCCESS = 3
EVT_STATE_FAILURE = 4

--[[
  2
0   1    4 5
  3
]]
EVENTS = {
    {
        pattern = {1, 3, 2, 2},
        name = 'your beer ran out!!',
        messages = {'toss it', 'grab it', 'crack it', 'chug it'},
        timer = 90,
        failure = {
            message = 'you spilled it everywhere!!',
            timer = 30,
            action = function()
                car.direction = 1
                car.paletteSwap[12] = 9
            end
        }
    },
    {
        pattern = {3, 0, 1, 0},
        name = 'the kids are makin\' noise!!',
        messages = {'turn around', 'a' ,'b', 'c'},
        timer = 90,
    }
}

EVENT_FAILURES = {
    {
        message = 'you put it in park!!',
        timer = 20,
        action = function()
            car.speed = 0
            car.accel = 0
        end
    },
    {
        message = 'your gut hit the wheel!!',
        timer = 30,
        action = function()
        end
    }
}

function makeEventFsm()
    local fsm = {}

    fsm.state= EVT_STATE_IDLE
    fsm.timer = 100 + rnd(100)
    fsm.frames = 1
    fsm.eventCounter = 0

    fsm.update = function()
        fsm.frames += 1
        if fsm.state == EVT_STATE_IDLE then
            if fsm.timer > 0 then
                fsm.timer -= 1
            else
                fsm.state = EVT_STATE_1
                fsm.eventCounter += 1
                fsm.event = EVENTS[flr(rnd(#EVENTS) + 1)]
                fsm.combo = {}
                fsm.timer = fsm.event.timer
            end
        elseif fsm.state == EVT_STATE_1 then
            if #fsm.combo == #fsm.event.pattern then
                fsm.state = EVT_STATE_SUCCESS
                fsm.timer = 60
                return
            end

            if fsm.timer == 0 then
                if fsm.event.failure then
                    fsm.failure = fsm.event.failure
                else
                    fsm.failure = EVENT_FAILURES[flr(rnd(#EVENT_FAILURES) + 1)]
                end
                fsm.state = EVT_STATE_FAILURE
                fsm.failureTimer = fsm.failure.timer
                fsm.timer = 60
                return
            end

            fsm.timer -= 1

            local nextComboChar = fsm.event.pattern[#fsm.combo + 1]
            if btnp(nextComboChar) then
                add(fsm.combo, nextComboChar)
            elseif band(btnp(), 0xF) > 0 then
                fsm.combo = {}
            end
        else
            if fsm.state == EVT_STATE_SUCCESS or fsm.state == EVT_STATE_FAILURE then
                if fsm.timer > 0 then
                    fsm.timer -= 1
                else
                    fsm.state = EVT_STATE_IDLE
                    fsm.timer = 50 + rnd(100) + max(0, 200 - fsm.eventCounter*30)
                    printh('ff: '..fsm.frames..' ft: '..fsm.timer)
                    fsm.event = nil
                    fsm.combo = {}
                end
            end

            if fsm.state == EVT_STATE_FAILURE then
                if fsm.failureTimer > 0 then
                    fsm.failureTimer -= 1
                    fsm.failure.action()
                end
            end
        end
    end

    fsm.draw = function()
        local starty = 12
        if fsm.state == EVT_STATE_1 then
            printShadowed(fsm.event.name, 64, starty+2, 9)

            if #fsm.combo < #fsm.event.messages then
                printShadowed(fsm.event.messages[#fsm.combo + 1], 64, starty+11, getFlashingCol())
            end

            -- gordon bennet
            for i = 1, #fsm.event.pattern do
                local sprite = 2
                local flipx = false
                local flipy = false
                local char = fsm.event.pattern[i]
                local comboChar = fsm.combo[i]
                if (char == 3) flipy = true
                if (char == 1) sprite = 3
                if (char == 0) sprite = 3 flipx = true
                if comboChar != char then
                    pal(7, 4)
                end
                spr(sprite, 46 + (i - 1) * 9, starty+20, 1, 1, flipx, flipy)
                pal()
            end

            local timeLeft = fsm.timer/fsm.event.timer
            line(46, starty+29, 46 + timeLeft * 36, starty+29)
        elseif fsm.state == EVT_STATE_SUCCESS then
            printShadowed('success!!', 64, starty+2, getFlashingCol())
        elseif fsm.state == EVT_STATE_FAILURE then
            printShadowed(fsm.failure.message, 64, starty+2, getFlashingCol())
        end
    end

    return fsm
end

function getFlashingCol()
    if (frame / 2) % 2 == 0 then
        return COL_TEXT_FLASH
    end
    return COL_TEXT
end

function printShadowed(str, x, y, col)
    -- jesus
    printCentered(str, x, y + 2, 2)
    printCentered(str, x-1, y + 2, 2)


    printCentered(str, x, y - 1, 4)
    printCentered(str, x+1, y - 1, 4)
    printCentered(str, x-1, y - 1, 4)

    printCentered(str, x+1, y, 4)
    printCentered(str, x-1, y, 4)

    printCentered(str, x, y + 1, 4)
    printCentered(str, x+1, y + 1, 4)
    printCentered(str, x-1, y + 1, 4)


    printCentered(str, x, y, col)
end

function printCentered(str, x, y, col)
    print(str, x - #str/2 * 4, y, col)
end

function printTable(tbl, cb)
    local output = ''
    for k, v in pairs(tbl) do
        if type(v) == 'string' or type(v) == 'number' then
            output = output .. k .. ': ' .. v .. ' '
        elseif type(v) == 'boolean' then
            output = output .. k .. ': ' .. (v and 'T' or 'F') .. ' '
        end
    end
    if cb then
        cb(output)
    else
        print(output)
    end
end

track = generateTrack(4) -- for fuck sake move this
-- track = {createSeg(1, 1000, SEG_STRAIGHT)}
