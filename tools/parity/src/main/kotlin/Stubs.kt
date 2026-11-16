// Just enough of the Android scan-record API for core/HexUtils.kt to compile on a plain JVM.
// Nothing here is ever called by the generator.
package android.bluetooth.le

class StubSparseArray {
    fun size(): Int = 0
    fun keyAt(index: Int): Int = 0
    fun valueAt(index: Int): ByteArray? = null
}

class StubParcelUuid(val uuid: java.util.UUID)

class ScanRecord {
    val manufacturerSpecificData: StubSparseArray = StubSparseArray()
    fun getManufacturerSpecificData(manufacturerId: Int): ByteArray? = null
    val serviceUuids: List<StubParcelUuid>? = null
    val serviceData: Map<StubParcelUuid, ByteArray>? = null
    val bytes: ByteArray? = null
}
