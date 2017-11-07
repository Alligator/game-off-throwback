-- constants
PI = 3.14159
SPR_ROAD = 0
ROAD_HEIGHT = 58

SPR_MID_BG = 64
COL_SKY = 12
COL_GROUND = 3

car = {
    speed=0,
    maxSpeed=80,
    accel=0,
    maxAccel=0.5,
    brakeAccel=-2.5,
    gear=0,
    pos=0,
    xpos=56,
    direction=0, -- -1 left, 1 right
    curSeg=nil,
    update=function(self)
        if self.speed >= 0 then
            self.speed += self.accel
            if self.speed < 0 then self.speed = 0 end
            if self.speed > self.maxSpeed then self.speed = self.maxSpeed end
            self.pos += self.speed / 20
        end

        if self.curSeg != nil then
            self.xpos += self.curSeg.seg[2]
        end

        self.xpos += self.direction * 2

        if self.speed == 0 then
            self.accel = 0
        elseif self.accel > self.maxAccel then
            self.accel = self.maxAccel
        end
    end
}

track = {
    {50, 0},
    {250, -1},
    {250, 0},
    {250, 1},
    {100, 0},
    {200, -1},
    {20, 0},
    {200, 1},
    {1000, 0}
}

updateq = {}
debugq = {}

function _init()
    cls()
    -- sfx(0)
end

function _draw()
    cls()

    drawBackground()
    drawRoad()
    drawCar()

    local offset = 0
    for item in all(debugq) do
        print(item, 0, offset)
        offset += 8
    end
    debugq = {}
end

function _update()
    if btn(5) then
        car.accel = car.brakeAccel
    elseif btn(4) then
        car.accel += 0.05
    else
        if car.accel > -car.maxAccel then
            car.accel += -0.05
        end
    end

    car.direction = 0
    if btn(0) then
        car.direction = -1
    end
    if btn(1) then
        car.direction = 1
    end

    rpm = (car.speed % (car.maxSpeed/3 + 1)) + car.speed / 5

    poke(0x3200, rpm * 0.65)
    poke(0x3200 + 1, 0x6c)
    poke(0x3200 + 2, rpm)
    poke(0x3200 + 3, 0x67)

    add(debugq, car.pos)

    add(updateq, car)

    car.curSeg = getCurrentSeg(track)
    for item in all(updateq) do
        item.update(item)
    end

    updateq = {}
end

function getCurrentSeg(track)
    local sum = 0
    for seg in all(track) do
        if car.pos > sum and car.pos < (sum + seg[1]) then
            return {
                seg=seg,
                segPos=car.pos - sum,
                totalPos=(sum + seg[1]) - car.pos
            }
        end
        sum += seg[1]
    end
end

function drawRoad()
    local curSeg = car.curSeg
    if curSeg != nil then
        add(debugq, 'cs: '.. curSeg.seg[1] .. ', ' .. curSeg.seg[2])
    end

    for y = 128, 128 - ROAD_HEIGHT, -1 do
        local z = abs(-64 / (y - 64))
        local scale = 1/z
        local width = 128 * scale
        local skew = (64 - (car.xpos + 8)) * scale
        local margin = (128 - width) / 2
        local texCoord = (z * 8 + car.pos) % 8

        local curveOffset = 0
        if curSeg != nil and curSeg.seg[2] != 0 then
            local curveScale = 1 - abs((curSeg.segPos - (curSeg.seg[1] / 2)) / (curSeg.seg[1] / 2)) -- jfc
            --[[
                ok wtf is going on here
                curveScale =
                    0 at the start of a curve
                    1 as we approach the centre
                    0 at the end of a curve
            ]]--
            local distScale = 1 - ((y - (128 - ROAD_HEIGHT)) / ROAD_HEIGHT)
            curveOffset = sin(curSeg.seg[2] * curveScale / 4 * distScale) * distScale * 25
            printh(y..' '..curveOffset..' ' ..distScale)
        end

        sspr(SPR_ROAD, SPR_ROAD+texCoord, 8, 1, margin + skew + curveOffset, y, width/2 + 1, 1)
        sspr(SPR_ROAD, SPR_ROAD+texCoord, 8, 1, margin + width/2 + skew + curveOffset, y, width/2, 1, true)
    end
end

function drawCar()
    local sprX = 32
    local width = 32
    local height = 24
    local split = 4
    local y = 124 - height
    if car.direction != 0 then
        local splitWidth = width/split

        pal(7, 4, 0) -- white
        pal(15, 4, 0) -- brown
        pal(8, 4, 0) -- red
        pal(12, 4, 0) -- blue
        sspr(sprX, 8, width, height, 64-width/2 + car.direction, y)
        pal()

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
        sspr(sprX, 8, width, height, 64-width/2, y)
    end
end

function drawBackground()
    rectfill(0, 0, 128, 56, COL_SKY)
    rectfill(0, 72, 128, 128, COL_GROUND)
    sspr(0, 32, 8, 16, 0, 56, 128, 16)
    -- spr(SPR_MID_BG, 0, 61, 128, 8)
end
