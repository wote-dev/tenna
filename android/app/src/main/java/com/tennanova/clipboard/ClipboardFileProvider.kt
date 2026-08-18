package com.tennanova.clipboard

import androidx.core.content.FileProvider

/** Dedicated subclass: using FileProvider directly is unreliable on some OEM builds. */
class ClipboardFileProvider : FileProvider()
