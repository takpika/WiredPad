# macOS 27.2 Sidecar入力経路のローカル調査

調査対象はこのMacにインストールされた `/usr/libexec/SidecarDisplayAgent`、`/System/Library/PrivateFrameworks/UniversalHID.framework`、`/System/Library/PrivateFrameworks/SkyLight.framework`。Appleのソースコードは含まれておらず、以下はバイナリのシンボルと文字列、WiredPadの実測から得た結果です。

## 確認できたこと

1. `SidecarDisplayAgent` は `CGVirtualDisplay` 系と `IOHIDUserDeviceCreateWithProperties` のほか、`IOHIDVirtualServiceClientCreate` と `IOHIDVirtualServiceClientDispatchEvent` を読み込みます。`IOHIDEventCreateDigitizerEvent` と `IOHIDEventAppendEvent` も読み込みます。
2. 同じ実行ファイルは `UniversalHID.HIDServiceProperties` の `cgDirectDisplayID`、`displayIdentifier`、`displayIntegrated`、`appleVendorSupported` のsetterを読み込みます。`UniversalHID` バイナリに対応する文字列 `CGDirectDisplayID`、`DisplayIntegrated`、`AppleVendorSupported` があります。
3. `SidecarDisplayAgent` には `TouchScreenDigitizer`、`configureTouchScreenDigitizer(for:with:)`、`supportsNativeTouches`、`supportsMacOSCompatibleTouchReports` に関するシンボル・文字列があります。iPad側の対応能力に応じてタッチ経路を構成することを示唆します。
4. `IOHIDVirtualServiceClientCreate` の呼び出しでは、Sidecarは `IOHIDEventSystemClientCreateWithType(..., 1, ...)` で作ったクライアント、5個のコールバック、コンテキストを渡します。作成後は `IOHIDVirtualServiceClientDispatchEvent` でイベントを渡します。
5. WiredPadは `HIDVirtualDevice` の `extraProperties` に `CGDirectDisplayID` を渡せます。IORegistryの `IOHIDUserDevice` には仮想ディスプレイIDが出ます。しかし子の `AppleUserHIDEventDriver` には同じ属性が現れず、10点レポート送信後のAppKit受信数は0です。
6. `IOHIDEventSystemClientCreateSimpleClient` からの `IOHIDEventSystemClientCopyServices` は、この環境ではサービス一覧を返しません。`IOHIDVirtualServiceClientCreate` は単独プログラムでもHID開発用エンタイトルメント付きWiredPad内でもNULLを返しました。コールバックは空の診断実装でしたが、後の計測では作成時に一度も呼ばれていません。
7. `SidecarDisplayAgent` は親Digitizerイベントに指ごとの子イベントを `IOHIDEventAppendEvent` で追加し、`IOHIDVirtualServiceClientDispatchEvent` に渡します。Mac内のバイナリの呼び出し列で確認しました。
8. Sidecar本体の署名には `com.apple.iohideventsystem.server`、`com.apple.private.hid.client.event-dispatch`、`com.apple.private.hid.client.event-monitor` が含まれます。WiredPadの開発用署名にあるのは `com.apple.developer.hid.virtual.device` です。
9. 署名済みWiredPad内で低レベルの `io_hideventsystem_create_virtual_service` を呼ぶと戻り値は `0` でしたが、出力サービスIDは `0` でした。`IOHIDVirtualServiceClientCreate` もNULLを返し、5つのコールバックは一度も呼ばれませんでした。空の属性と、`Transport`、`PrimaryUsagePage`、`PrimaryUsage`、`CGDirectDisplayID`、`DisplayIntegrated` などを含む属性の両方で同じ結果でした。従って戻り値0だけでサービス作成成功とは判断できません。単独の未署名プログラムでは低レベル呼び出しは `invalid destination port` でした。
10. CoreHID側にも `DisplayIdentifier`、`DisplayIntegrated`、`AppleVendorSupported` を追加して10点HID自己診断を実行しましたが、AppKit受信は0回でした。この属性変更は効果がなかったため戻しました。
11. 仮想HIDの `IOHIDUserDevice` には画面IDがあり、子の `AppleUserHIDEventDriver` にはありません。単独プログラムから子サービスへ `IORegistryEntrySetCFProperty(CGDirectDisplayID)` を呼ぶと `kIOReturnNotPermitted (0xe00002e2)` でした。HID開発用署名を持つWiredPad内では同じ呼び出しは成功値 `0` を返しましたが、子サービスのIORegistryに画面IDは現れず、10点HID送信後もAppKitの直接タッチ受信は0回でした。戻り値だけでは内部で適用されたか判断できません。この診断コードは成果物から外しています。
12. Appleの公開HIDDriverKitには `IOUserHIDEventService.dispatchDigitizerTouchEvent` があり、接触点の配列をシステムへ渡せます。ただし別途DriverKitの `com.apple.developer.driverkit`、`com.apple.developer.driverkit.transport.hid`、`com.apple.developer.driverkit.family.hid.eventservice` が必要です。これらは現在のWiredPad開発用プロファイルに含まれません。DriverKit経由ならmacOS 27のAppKit直接タッチへ届くかは未検証です。
13. `DriverKitPrototype` に、WiredPad仮想HIDへマッチし10点レポートを `dispatchDigitizerTouchEvent` に渡す試作を作成し、DriverKit 27.2 SDKで署名なしコンパイルに成功しました。権限とシステム拡張のホストアプリが未準備のため、実行テストはしていません。
14. その後、DriverKit開発用権限とSystem Extension権限を持つ署名済みビルドを実機へインストールしました。拡張0.3は有効になり、`IORegistry`のイベントキュー数と`hidutil dump services`のDigitizer件数がiPad入力に応じて増えます。つまりWiredPadのHIDレポートはDriverKitでDigitizerイベントへ変換され、WindowServerまで届いています。
15. WindowServerの`com.apple.BackBoard:TouchEvents`ログには `ignoring digitizer event for display <main> from unsupported service` と出ました。サービスは`eventSource: externalAccessory`で、仮想画面IDを`CGDirectDisplayID`としてHIDサービスへ設定しても`<main>`に解釈されています。これはAppKitが0回の直接の原因です。
16. 仮想HID機器の`Built-In`属性を一時的に`Yes`にしたところ、WindowServerの判定は`eventSource: builtin; authenticated`に変わり、`acquired main display digitizer`と`BKDirectTouchState`の生成を確認しました。ただし公開HIDDriverKit拡張のマッチングが外れてApple標準のイベントドライバへ切り替わり、対象画面もメインのままでした。AppKitの直接タッチ受信は0回でした。試験後、`Built-In`変更は取り消しました。
17. 拡張の`IOProbeScore`を2000から20000へ上げて`Built-In`機器へのマッチングを試しても、拡張は有効状態のまま実際のHID機器にはマッチしませんでした。`Built-In`と高いスコアの試験設定は取り消し、拡張0.5で通常のマッチングに戻りました。
18. 公開ColorSyncの`CGDisplayCreateUUIDFromDisplayID`で仮想画面のUUID取得を試み、CoreHID仮想機器の`DisplayIdentifier`属性も試しました。しかし同属性はIORegistryのHIDサービスに現れず、10点レポートを送った後もWindowServerは`display <main>`と`unsupported service`を記録しました。追加設定は取り消しました。後の実機再試験では、このAPIが仮想画面IDに対して`nil`を返すことを確認しました。
19. 拡張0.6では受信レポートと配送数を`HIDEventServiceProperties`に記録しました。10点自己診断でレポートID1、長さ62バイト、入力種別0、最大接触数10、`dispatchDigitizerTouchEvent`の戻り値0を実機で確認しました。これによりDriverKitの`handleReport`が実行され、10接触の配送呼び出しが成功していると分かりました。ただしWindowServerのログに見えるDigitizer親イベントは接触点の子イベントが空で、サービスも引き続き`unsupported service`として破棄されます。
20. 拡張0.7からは仮想HIDを作成した後、DriverKitのイベントサービスに `Built-In = Yes` を設定しました。DriverKitのマッチングを維持したまま、WindowServerは `eventSource: builtin; authenticated; builtIn` と認識し、`BKDirectTouchState` を生成しました。拡張1.1の10点自己診断では `touchstats` が `down: 10`、`up: 10`、接触ID `0〜9` を記録しました。ただし対象は `<main>` で、仮想画面のAppKit受信は0回です。
21. `CGDisplayCreateUUIDFromDisplayID` は接続中の仮想画面IDに対して `nil` を返しました。CoreHIDの `uniqueID` に代用の識別子を与えてもIORegistryには現れず、長い文字列を `serialNumber` に与えると仮想HIDの作成が失敗しました。試験後にシリアル番号を元の `1` へ戻し、拡張1.1で10点のWindowServer到達を再確認しました。
22. CoreGraphics内部の `CGSCopyDisplayUUID` は接続後の仮想画面に実UUIDを返しました。画面生成直後には取得できないため、ScreenCaptureKitで画面の登録を確認してからHIDを作ります。CoreHID仮想機器の `serialNumber` にUUID文字列を渡すとIORegistryへ到達し、DriverKitが親サービスから読めました。
23. `UniversalHID.HIDServicePropertyKey.displayIdentifier` の実装を逆アセンブルすると、HIDのキー名は `DisplayIdentifier` ではなく小文字始まりの `displayUUID` でした。DriverKitサービスにこのキーで仮想画面UUIDを設定すると、WindowServerの `BKIOHIDService` と `touchstats` にUUIDが現れ、「No display UUID for sender」のログが解消しました。
24. SidecarDisplayAgentは `cgDirectDisplayID`、`displayIdentifier`、`displayIntegrated` のsetterを参照しますが、`builtIn` のsetterは参照しません。WiredPadも拡張1.7から `Built-In` を外して `displayUUID` と `DisplayIntegrated` を設定しました。WindowServerは `eventSource: externalAccessory` と認識しながら10接触を仮想画面UUIDへ配送しました。
25. 拡張1.7でiPadの実タッチを試すと、Macアプリは最大10点を受信・HID送信し、仮想画面上の `NSGestureRecognizer` は227回、同時最大10点の直接タッチを記録しました。拡張1.8では `NSIsTouchNative` を有効にし、同じ実機接続でAppKitの直接タッチ161回・同時最大10点を再確認しました。拡張1.8は `systemextensionsctl list` で `[activated enabled]`、ホストアプリは `codesign --verify --strict` 成功です。

## 結論

このMacでは、Sidecarの私有HID権限を使わずに、開発用CoreHID権限とHIDDriverKit拡張で仮想画面上のAppKit直接タッチを最大10点まで実機確認しました。重要だったのは仮想画面の実UUIDを `displayUUID` としてHIDイベントサービスへ渡すことです。`Built-In` は不要でした。

仮想画面の生成とUUID取得にはCoreGraphicsの非公開APIを使います。macOS 27.2での検証結果であり、OS更新時には再検証が必要です。
