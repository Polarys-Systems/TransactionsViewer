package ui

import "core:math"

/*
Small value animation helpers.

These do not know about UI_State or microui. Callers own the lifetime and feed
the sampled values into layout/style/draw code.
*/

UI_Ease :: enum {
	Linear,
	Out_Quad,
	In_Out_Quad,
	Out_Cubic,
	Smoothstep,
}

UI_Anim_Float :: struct {
	value:    f32,
	from:     f32,
	target:   f32,
	elapsed:  f32,
	duration: f32,
	ease:     UI_Ease,
	active:   bool,
}

ease_sample :: proc(t: f32, ease: UI_Ease = .Out_Cubic) -> f32 {
	x := math.clamp(t, 0.0, 1.0)
	switch ease {
	case .Linear:
		return x
	case .Out_Quad:
		return 1.0 - (1.0-x)*(1.0-x)
	case .In_Out_Quad:
		if x < 0.5 {
			return 2.0 * x * x
		}
		f := 2.0 - 2.0*x
		return 1.0 - f*f*0.5
	case .Smoothstep:
		return x * x * (3.0 - 2.0*x)
	case .Out_Cubic:
		f := 1.0 - x
		return 1.0 - f*f*f
	}
	return x
}

anim_float_set :: proc(anim: ^UI_Anim_Float, value: f32) {
	if anim == nil {
		return
	}
	anim.value = value
	anim.from = value
	anim.target = value
	anim.elapsed = 0.0
	anim.duration = 0.0
	anim.active = false
}

anim_float_to :: proc(
	anim: ^UI_Anim_Float,
	target: f32,
	duration: f32 = 0.18,
	ease: UI_Ease = .Out_Cubic,
) {
	if anim == nil {
		return
	}
	anim.from = anim.value
	anim.target = target
	anim.elapsed = 0.0
	anim.duration = max(duration, 0.0)
	anim.ease = ease
	anim.active = anim.duration > 0.0 && anim.from != anim.target
	if !anim.active {
		anim.value = target
	}
}

anim_float_tick :: proc(anim: ^UI_Anim_Float, dt_seconds: f32) -> f32 {
	if anim == nil {
		return 0.0
	}
	if !anim.active {
		return anim.value
	}
	anim.elapsed += max(dt_seconds, 0.0)
	t := f32(1.0)
	if anim.duration > 0.0 {
		t = math.clamp(anim.elapsed / anim.duration, 0.0, 1.0)
	}
	k := ui_ease_sample(t, anim.ease)
	anim.value = anim.from + (anim.target-anim.from) * k
	if t >= 1.0 {
		anim.value = anim.target
		anim.active = false
	}
	return anim.value
}

anim_float_settled :: proc(anim: ^UI_Anim_Float, epsilon: f32 = 0.001) -> bool {
	if anim == nil {
		return true
	}
	return !anim.active && abs(anim.value-anim.target) <= epsilon
}
