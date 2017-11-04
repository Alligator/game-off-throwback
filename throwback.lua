-- constants
SPR_ROAD = 0
ROAD_HEIGHT = 58

car = {
    speed=0,
    maxSpeed=80,
    accel=0,
    maxAccel=0.5,
    brakeAccel=-2.5,
    gear=0,
    pos=0,
    xpos=56,
    update=function(self)
        if self.speed >= 0 then
            self.speed += self.accel
            if self.speed < 0 then self.speed = 0 end
            if self.speed > self.maxSpeed then self.speed = self.maxSpeed end
            self.pos += self.speed / 16
        end

        if self.speed == 0 then
            self.accel = 0
        elseif self.accel > self.maxAccel then
            self.accel = self.maxAccel
        end
    end
}

track = {
    {50, 0},
    {25, -1},
    {25, 0},
    {25, 1}
}

updateq = {}

function _init()
    cls()
    sfx(0)
end

function _draw()
    cls()
    print(car.speed, 0, 0)
    print(car.accel, 0, 8)
    print(car.xpos, 0, 16)
    print(peek(0x3200), 0, 24)

    drawRoad()
    drawCar()
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

    if btn(0) then
        car.xpos -= 2
    end
    if btn(1) then
        car.xpos += 2
    end

    rpm = (car.speed % (car.maxSpeed/3 + 1)) + car.speed / 5

    poke(0x3200, rpm * 0.65)
    poke(0x3200 + 1, 0x6c)
    poke(0x3200 + 2, rpm)
    poke(0x3200 + 3, 0x67)

    add(updateq, car)

    for item in all(updateq) do
        item.update(item)
    end

    updateq = {}
end

function drawRoad()
    for y = 128, 128 - ROAD_HEIGHT, -1 do
        local z = abs(-64 / (y - 64))
        local scale = 1/z
        -- if y == 64 then zScale = 0 end
        local width = 128 * scale
        local skew = (64 - (car.xpos + 8)) * scale
        -- printh(y .. " z:" .. z .. " s:" .. scale)
        local margin = (128 - width) / 2
        local texCoord = (z * 8 + car.pos) % 8
        sspr(SPR_ROAD, SPR_ROAD+texCoord, 8, 1, margin + skew, y, width/2 + 1, 1)
        sspr(SPR_ROAD, SPR_ROAD+texCoord, 8, 1, margin + width/2 + skew, y, width/2, 1, true)
    end
end

function drawCar()
    sspr(0, 8, 16, 16, 56, 128-17)
end
