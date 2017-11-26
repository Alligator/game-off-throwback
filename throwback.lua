-- autocmd BufWritePost <buffer> silent make
PI = 3.14159
ROAD_HEIGHT = 58
INIT_TIMER = 60

SPR_ROAD = 0
SPR_FINISH = 8
SPR_0 = 224
SPR_MID_BG = 64

SFX_CAR_CHANNEL = 2
SFX_CHANNEL = 3
SFX_CRASH = 4

PICKUP_COLLECTED_TIMER = 60

CIG_FRAMES = {
    { sx = 64, sy = 0, width = 9, height = 16, offset = 0 },
    { sx = 73, sy = 0, width = 7, height = 16, offset = 1 },
    { sx = 78, sy = 0, width = 3, height = 16, offset = 3 },
    { sx = 73, sy = 0, width = 7, height = 16, offset = 0, fliph = true },
}

COL_SKY = 12
COL_GROUND = 3
COL_TEXT = 9
COL_TEXT_FLASH = 7

SEG_RIGHT = 1
SEG_STRAIGHT = 0
SEG_LEFT = -1

SCENES = {
    { pos = 0, pal = {} },
    { pos = 2000, pal = { [3] = 2, [12] = 14 } },
    { pos = 4000, pal = { [3] = 5, [12] = 1 } },
}

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
    maxTurnAccel = 0.2,
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
    crashed=false,
    playedCrashSfx=false,
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
            self.xpos += -self.curSeg.seg.dir * ((self.speed / self.maxSpeed) * self.curSeg.seg.angle / 20)
        end

        -- off track
        if self.xpos < 0 or self.xpos > 128 then
            if self.speed > self.maxSpeed/4 then
                self.accel = -self.maxAccel
            end

            self.xpos = max(min(self.xpos, 152), -42)
        end

        if self.crashed and not self.playedCrashSfx then
            sfx(SFX_CRASH, SFX_CHANNEL)
            self.playedCrashSfx = true
        end
        if not self.crashed then self.playedCrashSfx = false end
    end,

    stop=function(self, x)
        self.speed = 0
        self.accel = 0
    end,

    checkCollision=function(self, x)
        return abs((self.xpos + 12) - x) < 12
    end,
}

updateq = {}

eventFsm = nil
timer = 0
powerups = {}
timePowerupSpawned = false

attractMusicSpeed = peek(0x3200 + (68 * 5) + 65)

function _init()
    cls()
    music(1)
end

function _draw()
    cls()

    if gameState == STATE_NOT_STARTED then
        drawAttract()
    elseif gameState == STATE_DRIVING then
        drawBackground()
        drawRoad()
        drawCar()
        drawCollectedPowerups()

        if driveTextCounter < 100 then
            drawDriveText()
            driveTextCounter += 1
        end

        if eventFsm != nil then
            eventFsm.draw()
        end
        drawTimer()
    elseif gameState == STATE_GAME_OVER then
        drawGameOverText()
    else
        sfx(-1)
        drawFinishText()
    end

    frame += 1
end

function _update()
    car.curSeg = getSeg(track, car.pos, true)

    if gameState == STATE_NOT_STARTED then
        updateAttract()
    elseif gameState == STATE_DRIVING then
        sfx(0, SFX_CAR_CHANNEL)
        if eventFsm == nil then
            eventFsm = makeEventFsm()
        end
        updateTimer()
        updateCar()
        updatePowerUps()
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

    elseif gameState == STATE_GAME_OVER then
        -- if btnp(4) then
        --     run()
        -- end
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
        sfx(-1, SFX_CAR_CHANNEL)
    elseif timer < 15 and not timePowerupSpawned then
        timePowerupSpawned = true
    end
end

function updatePowerUps()
    local foundCigs = false
    for pup in all(powerups) do
        if pup.name == 'cigs' then
            foundCigs = true
        end

        if pup.collected then
            if pup.collectedTimer == 0 then
                del(powerups, pup)
            else
                pup.collectedTimer -= 1
            end
        elseif pup.pos - car.pos < 10 then
            local pupX = pup.xpos + 64 + (pup.anim[1].width/2)
            if car:checkCollision(pupX) then
                pup:onPickup()
                pup.collected = true
                pup.collectedTimer = PICKUP_COLLECTED_TIMER
            elseif pup.pos - car.pos < 0 then
                del(powerups, pup)
            end
        end
    end

    if (flr(timer) == 20 or flr(timer) == 5) and not foundCigs then
        add(powerups, makeCigs())
    end
end

function makeCigs()
    return {
        name = 'cigs',
        pos = car.pos + 200,
        xpos = rnd(64) - 32,
        anim = CIG_FRAMES,
        message = "+20 seconds",
        onPickup=function(self)
            timer += 20
        end,
    }
end

function updateAttract()
    -- speed = 36, 36 ticks per beat. 2 bars of 3/4, 12 beats
    if stat(26) >= (attractMusicSpeed * 12) - 1  then
        music(1)
    end
    if btn(4) then
        gameState = STATE_DRIVING
        timer = INIT_TIMER
        music(0)
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

    curSeg = getCu

    add(updateq, car)
end

roadLineOffsets = {}

function drawRoad()
    local curSeg = car.curSeg
    car.crashed = false -- what a terrible place to do this

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
            curveOffset = sin(-curSeg.seg.dir * curveScale / 4 * distScale / (scale * 16)) * distScale * curSeg.seg.angle
        end

        roadLineOffsets[y] = { curveOffset = curveOffset, skew = skew }

        local ySeg = getSeg(track, car.pos + z * 7, false) -- i don't know why 7 works here
        if ySeg != nil and ySeg.seg.isFinish then
            palt(0, false)
            sspr(SPR_FINISH, texCoord, 8, 1, margin + skew + curveOffset, y, width/2 + 1, 1)
            sspr(SPR_FINISH, texCoord, 8, 1, margin + width/2 + skew + curveOffset, y, width/2, 1)
            palt()
        else
            sspr(SPR_ROAD, texCoord, 8, 1, margin + skew + curveOffset, y, width/2 + 1, 1)
            sspr(SPR_ROAD, texCoord, 8, 1, margin + width/2 + skew + curveOffset, y, width/2, 1, true)
        end

        local proj = car.pos + z * 8
        local pproj = car.pos + (abs(-64 / (y - 63))) * 8
        local nproj = car.pos + (abs(-64 / (y - 65))) * 8
        if ySeg != nil then
            for name in all(ySeg.seg.hazards) do
                local density = 32
                local hazard = HAZARDS[name]
                if proj % density < pproj % density and proj % density < nproj % density then
                    local xpos1 = (width/2) + 64
                    local xpos2 = (width/2) - 64
                    local height = hazard.height * scale * 2
                    local width = hazard.width * scale * 2
                    if hazard.palt != nil then
                        palt(hazard.palt, true)
                        palt(0, false)
                    end

                    if name != 'turnSign' or ySeg.seg.dir == SEG_LEFT then
                        drawAndCheckHazard(hazard,
                            xpos1 + skew + curveOffset, y-height,
                            width, height, false, true)
                    end
                    if name != 'turnSign' or ySeg.seg.dir == SEG_RIGHT then
                        drawAndCheckHazard(hazard,
                            (skew + curveOffset) - xpos2 - width, y-height,
                            width, height, true, false)
                    end
                    palt()
                end
            end
        end

        for powerup in all(powerups) do
            local projDiff = abs(powerup.pos - proj)
            if not powerup.collected and projDiff < abs(powerup.pos - nproj) and projDiff < abs(powerup.pos - pproj) then
                local animFrame = powerup.anim[flr((frame/4) % #powerup.anim) + 1]
                local x = 64 + animFrame.offset + skew + curveOffset + (scale * powerup.xpos)
                palt(0, false) -- TODO this should be per sprite not a blanket thing
                sspr(animFrame.sx, animFrame.sy,
                    animFrame.width, animFrame.height,
                    x, 64,
                    animFrame.width * scale * 2, animFrame.height * scale * 2,
                    animFrame.fliph)
                palt()
            end
        end

        pal()
    end
end

function drawAndCheckHazard(hazard, dx, dy, dw, dh, fliph, isLeft)
    sspr(hazard.sx, hazard.sy, hazard.width, hazard.height, dx, dy, dw, dh, fliph)
    if dy + dh >= 110 then
        local x = -8
        if isLeft then
            x = 136
        end
        local xCol = x - hazard.width/2
        if isLeft then
            xCol = x + hazard.width/2
        end
        if car:checkCollision(xCol) then
            car:stop()
            car.crashed = true
        end
    end
end

function drawCar()
    local sprX = 32
    local width = 32
    local height = 24
    local split = 4
    local y = 100

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
        pal(12, 4, 0) -- blue
        sspr(sprX, 8, width, height, 64-width/2 + car.direction, y)
        pal()

        for k, v in pairs(car.paletteSwap) do
            pal(k, v)
        end

        if car.braking then
            pal(2, 8, 0)
        end

        for i = 0, split - 1 do
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
    drawBigNumberShadowed(flr(timer), 64, 6)
end

function drawBigNumberShadowed(num, x, y)
    pal(7, 2)
    drawBigNumber(num, x, y+1)
    pal()
    drawBigNumber(num, x, y)
end

function drawBigNumber(num, x, y)
    -- 2.1 precision
    local decimal = false
    local width = 8
    if num >= 10 then
        width += 8
    end
    if flr(num) != num then
        decimal = true
        width += 11
    end

    local curX = x - width/2
    if num >= 10 then
        local d1 = flr(num / 10)
        spr(SPR_0 + d1, curX, y)
        curX += 8
    end
    local d2 = flr(num % 10)
    spr(SPR_0 + d2, curX, y)
    curX += 9

    if decimal then
        local d3 = (num - flr(num)) * 10
        pset(curX, y + 7, 7)
        curX += 2
        spr(SPR_0 + d3, curX, y)
    end
end

function drawAttract()
    local roadY = 42
    local logoY = 32
    
    line(64, roadY - 16, 0, roadY + 48, 8)
    line(63, roadY - 16, -1, roadY + 48, 8)

    line(64, roadY - 16, 128, roadY + 48, 8)
    line(65, roadY - 16, 129, roadY + 48, 8)

    -- 70s
    sspr(0, 80, 28, 16, 31, logoY)
    -- dad
    sspr(29, 80, 33, 16, 64, logoY)
    
    local drvX = 32
    local kern = 4
    local width = 10
    pal(7, 9)
    -- d
    sspr(102, 64, 10, 16, drvX, logoY + 19)
    drvX += width + kern - 1
    -- r
    sspr(91, 64, 10, 16, drvX, logoY + 19)
    drvX += width + kern
    -- i
    sspr(69, 64, 3, 16, drvX, logoY + 19)
    drvX += 3 + kern
    -- v
    sspr(69, 64, 10, 16, drvX, logoY + 19)
    drvX += width + kern - 1
    -- i
    sspr(69, 64, 3, 16, drvX, logoY + 19)
    drvX += 3 + kern
    -- n
    sspr(113, 64, 10, 16, drvX, logoY + 19)
    drvX += width + kern
    -- '
    rect(drvX - kern + 1, logoY + 19, drvX - kern + 2, logoY + 21, 9)
    pal()

    local textY = 84
    printShadowed('press z to start', 64, textY, getFlashingCol())
    printShadowed('Z: ACCELERATE X: BRAKE', 64, textY + 10, 9)
end

function drawBackground()
    local currentScene
    for scene in all(SCENES) do
        if car.pos > scene.pos then
            currentScene = scene
        end
    end

    if currentScene != nil then
        for k, v in pairs(currentScene.pal) do
            pal(k, v)
        end
    end

    rectfill(0, 0, 128, 56, COL_SKY)
    rectfill(0, 72, 128, 128, COL_GROUND)
    sspr(0, 32, 8, 16, 0, 56, 128, 16)
    pal()
end

function drawFinishText()
    local width = 32
    local height = 14
    wigglyTiledSpr(8, 0, 56 - width/2, 56 - height/2, width + 16, height * 2)
    wigglySspr(0, 96, width, height, 64 - width/2, 64 - height/2)
end

function drawDriveText()
    local width = 32
    local height = 10
    wigglySspr(38, 96, width, height, 64 - width/2, 42)
end

function drawGameOverText()
    local width = 100
    local height = 15
    local y = 32 - height/2
    pal(7, 10)
    wigglySspr(0, 64, width, height, 64 - width/2, y - height - 1)
    pal(7, 9)
    wigglySspr(0, 64, width, height, 64 - width/2, y)
    pal(7, 8)
    wigglySspr(0, 64, width, height, 64 - width/2, y + height + 1)
    pal()

    local miles = flr(car.pos / 100) / 10
    local droveY = 62
    local boxWidth = 72
    local boxMargin = (128-boxWidth)/2

    rectfill(boxMargin, droveY + 2, 128-boxMargin, droveY + 62, 2)
    rect(boxMargin, droveY + 2, 128-boxMargin, droveY + 62, 4)

    printShadowed('results', 64, droveY, 7)

    printShadowed('you drove', 64, droveY + 9, COL_TEXT)
    drawBigNumber(miles, 64, droveY + 17)
    printShadowed('miles', 64, droveY + 28, COL_TEXT)
    printShadowed('- good job -', 64, droveY + 40, getFlashingCol())
    printShadowed('z to reset', 64, droveY + 53, COL_TEXT)
end

function drawCollectedPowerups()
    for pup in all(powerups) do
        if pup.collected then
            local animFrame = pup.anim[1]
            local a = pup.collectedTimer/PICKUP_COLLECTED_TIMER
            printShadowed(pup.message, 64, 64 + (16 * a), getFlashingCol())
        end
    end
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
    local track = {}
    for i = 1, segCount do
        -- don't repeat the same anything twice in a row
        local newSeg
        if #track == 0 then
            newSeg = createSeg(i, 100 + flr(rnd(100)), SEG_STRAIGHT, 0)
        else
            local prevSeg = track[#track]
            -- prefer curve if straight, prefer straight if curve
            local shouldChangeCurve = 75 > rnd(100)
            local nextDir = prevSeg.dir
            local nextAngle = rnd(50) + 10
            if shouldChangeCurve then
                if prevSeg.dir != SEG_STRAIGHT then
                    nextDir = 0
                    nextAngle = 0
                else
                    local r = rnd(100)
                    nextDir = (r <= 50 and SEG_LEFT or SEG_RIGHT)
                end
            end
            newSeg = createSeg(i, 100 + flr(rnd(250)), nextDir, nextAngle)
        end
        add(track, newSeg)
    end
    add(track, createSeg(segCount + 1, 2, 0, 0))
    track[#track].isFinish = true
    return addHazards(track)
end

-- for real why is lua so bad
HAZARD_NAMES = {'lamp', 'turnSign'}
HAZARDS = {
    turnSign = { -- this HAS to be first
        sx = 16,
        sy = 32,
        width = 16,
        height = 32,
        palt = 11,
    },
    lamp = {
        sx = 8,
        sy = 32,
        width = 8,
        height = 32
    },
}

function addHazards(track)
    for seg in all(track) do
        local sharpness = (seg.angle * 2) / seg.length
        if seg.dir != SEG_STRAIGHT and sharpness > 0.6 then
            seg.hazards = { 'turnSign' }
        else
            -- local name = HAZARD_NAMES[flr(rnd(#HAZARD_NAMES))] -- skip the first one
            local name = 'lamp' -- whatever this will work when #HAZARDS is > 2
            seg.hazards = { name }
        end
    end
    return track
end

function createSeg(id, length, direction, angle)
    return {
        id=id,
        length=length,
        dir=direction,
        angle=angle,
        hazards={},
    }
end

function getSeg(track, pos, remove)
    local sum = trackOffset
    local itemsToRemove = {}
    local foundSeg = nil
    for i = 1, #track  do
        local seg = track[i]
        if pos > sum and pos < (sum + seg.length) then
            foundSeg = {
                seg=seg,
                segPos=pos - sum,
                totalPos=(sum + seg.length) - pos
            }
            break
        elseif remove then
            itemsToRemove[i] = sum + seg.length
        end
        sum += seg.length
    end

    -- remove segs behind the car
    for k, v in pairs(itemsToRemove) do
        -- using del here because in theory there's only ever one thing in
        -- itemsToRemove
        trackOffset = v
        del(track, track[k])
    end

    return foundSeg
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
U = 2
D = 3
L = 0
R = 1
EVENTS = {
    {
        pattern = {R, D, U, U},
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
        pattern = {D, L, R, L},
        name = 'the kids are makin\' noise!!',
        messages = {'turn around', 'hoot' ,'holler', 'whoop'},
        timer = 90,
        failure = {
            message = 'dang kids!!',
            timer = 30,
            action = function()
                if frame % 14 < 7 then
                    car.paletteSwap[12] = 14
                    car.direction = -1
                else
                    car.paletteSwap[12] = 8
                    car.direction = 1
                end
            end
        }
    },
    {
        pattern = {L, L, R, L},
        name = 'sports aren\'t on the radio!!',
        messages = {'where', 'are' ,'the', 'sports'},
        timer = 90,
        failure = {
            message = 'i\'m missing the game!!',
            timer = 30,
            action = function()
                car.braking = true
            end
        }
    },
}

function makeEventFsm()
    local fsm = {}

    fsm.state= EVT_STATE_IDLE
    fsm.timer = 200 + rnd(100)
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
                if fsm.eventCounter > 1 then
                    fsm.timer *= max(0.5, 1 - fsm.eventCounter/16)
                end
            end
        elseif fsm.state == EVT_STATE_1 then
            if #fsm.combo == #fsm.event.pattern then
                fsm.state = EVT_STATE_SUCCESS
                fsm.timer = 60
                return
            end

            if fsm.timer <= 0 then
                fsm.failure = fsm.event.failure
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
        local starty = 24
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
    if (frame % 4) <= 1 then
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
    output = formatTable(tbl)
    if cb then
        cb(output)
    else
        print(output)
    end
end

function formatTable(tbl)
    local output = ''
    for k, v in pairs(tbl) do
        output = output .. k .. ': '
        if type(v) == 'string' or type(v) == 'number' then
            output = output .. v .. ' '
        elseif type(v) == 'boolean' then
            output = output .. (v and 'T' or 'F') .. ' '
        elseif type(v) == 'table' then
            output = output .. formatTable(v) .. ' '
        else
            output = output .. '? '
        end
    end
    return '{ ' .. output .. ' }'
end

track = generateTrack(4)
trackOffset = 0
