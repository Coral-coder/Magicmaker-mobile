package com.magicmaker.android.ui

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

@Composable
fun RelayQrImage(content: String, modifier: Modifier = Modifier, sizeDp: Int = 200) {
    val bitmap = remember(content) { qrBitmap(content, sizeDp * 4) }
    if (bitmap != null) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = "Pairing QR code",
            modifier = modifier.size(sizeDp.dp),
        )
    }
}

private fun qrBitmap(content: String, px: Int): Bitmap? {
    return try {
        val hints = mapOf(EncodeHintType.MARGIN to 1)
        val matrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, px, px, hints)
        val w = matrix.width
        val h = matrix.height
        Bitmap.createBitmap(w, h, Bitmap.Config.RGB_565).apply {
            for (x in 0 until w) {
                for (y in 0 until h) {
                    setPixel(x, y, if (matrix[x, y]) Color.BLACK else Color.WHITE)
                }
            }
        }
    } catch (_: Exception) {
        null
    }
}
