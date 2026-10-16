-- Private bounded sampler for automatic reload requests, in integer milliseconds.
-- Mean and population variance are fitted before rounding to whole milliseconds.
return function(mean_ms, variance_ms2, seed)
    local lower, upper = 80, 150
    assert(type(mean_ms) == 'number' and mean_ms > lower and mean_ms < upper, 'mean outside bounds')
    local maximum_variance = (mean_ms - lower) * (upper - mean_ms)
    assert(type(variance_ms2) == 'number' and variance_ms2 > 0 and
        variance_ms2 < maximum_variance, 'variance outside feasible bounds')
    assert(type(seed) == 'number' and seed == seed and math.abs(seed) < math.huge, 'finite seed required')

    -- Exact intermediate integers below 2^53; shared math.random is untouched.
    local floor, log, sqrt, cos = math.floor, math.log, math.sqrt, math.cos
    local state = floor(math.abs(seed)) % 2147483646 + 1
    local function uniform()
        state = (state * 48271) % 2147483647
        return state / 2147483647
    end
    local width = upper - lower
    local m, v = (mean_ms - lower) / width, variance_ms2 / (width * width)
    local concentration = m * (1 - m) / v - 1
    local alpha, beta = m * concentration, (1 - m) * concentration
    local gamma
    gamma = function(shape)
        if shape < 1 then return gamma(shape + 1) * uniform() ^ (1 / shape) end
        local d = shape - 1 / 3
        local c = 1 / sqrt(9 * d)
        while true do
            local z = sqrt(-2 * log(uniform())) * cos(2 * math.pi * uniform())
            local w = 1 + c * z
            if w > 0 then
                w = w * w * w
                local u = uniform()
                if u < 1 - 0.0331 * z ^ 4 or log(u) < 0.5 * z * z + d * (1 - w + log(w)) then
                    return d * w
                end
            end
        end
    end
    return function()
        local a, b = gamma(alpha), gamma(beta)
        return floor(lower + width * a / (a + b) + 0.5)
    end
end
