package co.th.cjmart.cjx_triplog

import io.flutter.embedding.android.FlutterFragmentActivity

/// ต้องเป็น FlutterFragmentActivity (ไม่ใช่ FlutterActivity)
/// เพราะปลั๊กอิน local_auth ใช้ BiometricPrompt ซึ่งต้องการ FragmentActivity
class MainActivity : FlutterFragmentActivity()
