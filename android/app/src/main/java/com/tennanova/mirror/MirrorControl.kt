package com.tennanova.mirror

import org.json.JSONObject

sealed interface MirrorInput {
    val sessionId: String
    val inputId: String

    data class Tap(
        override val sessionId: String,
        override val inputId: String,
        val x: Float,
        val y: Float
    ) : MirrorInput

    data class SwipePoint(val x: Float, val y: Float, val t: Float)

    data class Swipe(
        override val sessionId: String,
        override val inputId: String,
        val points: List<SwipePoint>,
        val durationMs: Long
    ) : MirrorInput

    data class Global(
        override val sessionId: String,
        override val inputId: String,
        val action: Action
    ) : MirrorInput {
        enum class Action { BACK, HOME, RECENTS }
    }
}

data class MirrorInputValidation(val input: MirrorInput? = null, val error: String? = null)

object MirrorInputValidator {
    fun parse(message: JSONObject, activeSessionId: String?): MirrorInputValidation {
        val sessionId = message.optString("sessionId")
        val inputId = message.optString("inputId")
        if (!safeId(sessionId) || !safeId(inputId)) return failure("invalid_input")
        if (activeSessionId == null || sessionId != activeSessionId) return failure("stale_session")

        return when (message.optString("kind")) {
            "tap" -> {
                val x = coordinate(message, "x") ?: return failure("invalid_input")
                val y = coordinate(message, "y") ?: return failure("invalid_input")
                MirrorInputValidation(MirrorInput.Tap(sessionId, inputId, x, y))
            }

            "swipe" -> {
                val values = message.optJSONArray("points") ?: return failure("invalid_input")
                if (values.length() !in 2..32) return failure("invalid_input")
                val duration = message.optLong("durationMs", -1).coerceIn(80, 1_000)
                if (message.optLong("durationMs", -1) < 0) return failure("invalid_input")
                var lastT = -1f
                val points = buildList {
                    for (index in 0 until values.length()) {
                        val point = values.optJSONObject(index) ?: return failure("invalid_input")
                        val x = coordinate(point, "x") ?: return failure("invalid_input")
                        val y = coordinate(point, "y") ?: return failure("invalid_input")
                        val t = coordinate(point, "t") ?: return failure("invalid_input")
                        if (t < lastT) return failure("invalid_input")
                        lastT = t
                        add(MirrorInput.SwipePoint(x, y, t))
                    }
                }
                MirrorInputValidation(MirrorInput.Swipe(sessionId, inputId, points, duration))
            }

            "global" -> {
                val action = when (message.optString("action")) {
                    "back" -> MirrorInput.Global.Action.BACK
                    "home" -> MirrorInput.Global.Action.HOME
                    "recents" -> MirrorInput.Global.Action.RECENTS
                    else -> return failure("invalid_input")
                }
                MirrorInputValidation(MirrorInput.Global(sessionId, inputId, action))
            }

            else -> failure("invalid_input")
        }
    }

    private fun coordinate(value: JSONObject, key: String): Float? {
        if (!value.has(key)) return null
        val number = value.optDouble(key, Double.NaN)
        return number.takeIf { it.isFinite() && it in 0.0..1.0 }?.toFloat()
    }

    private fun safeId(value: String): Boolean =
        value.length in 1..64 && value.all { it.isLetterOrDigit() || it == '-' || it == '_' }

    private fun failure(error: String) = MirrorInputValidation(error = error)
}
