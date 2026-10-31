<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

<h1 align="center">WiredPad</h1>

<p align="center"><a href="README.md">English</a> | <b>日本語</b></p>

WiredPadは、iPadをmacOS 27のタッチスクリーンとして使うためのアプリです。macOS 27はタッチスクリーンからの直接タッチをAppKitアプリへ届けられます。WiredPadはUSBでつないだiPadを、そのタッチスクリーンにします。iPadに触れた指は、マウスのクリックではなく、最大10点のネイティブなマルチタッチとしてMacのアプリに届きます。

そのために、iPadの実解像度に合わせた仮想ディスプレイをMacに作り、HEVCまたはH.264のハードウェア処理でiPadへ映像を送ります。iPadのタッチは、HIDDriverKit拡張がその画面に結び付いたデジタイザとしてMacへ返します。iPad本体の音量ボタンもMacの音量キーとして使えます。

このリポジトリはソースコードです。インストール用の完成品ではありません。macOS 27.2のMacとiPadOS 26を搭載した第8世代iPadで動作を確認しました。他の機種やOSでは未検証です。

## 動作確認済みの機能

- 署名済みHIDDriverKit拡張を有効にした場合の、仮想画面上での最大10点のAppKit直接タッチ。
- USB経由の映像転送。VideoToolboxによるハードウェア圧縮・復号、HiDPI、iPadの画面更新上限への対応。
- iPadの物理音量ボタンによるMac音量操作。
- iPadのロック解除後とUSB抜き差し後の自動映像復帰。
- 日本語・英語のUI。ほかの言語は`Resources/<language>.lproj`に追加できます。

## 重要な制約

- 仮想画面の生成とUUID取得に、非公開の`CGVirtualDisplay`と`CGSCopyDisplayUUID`を使います。OS更新で動かなくなる可能性があります。[Appleは配布申請するアプリに文書化されたAPIの使用を求めています](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)。これは開発用の試作です。
- 映像取得はScreenCaptureKitを使用します。macOSの画面収録許可が必要で、接続中は画面共有の表示が出ます。
- 直接タッチには、Appleから付与されたHID Virtual DeviceとDriverKitの権限、署名証明書、対応するプロビジョニングプロファイルが必要です。リポジトリ内のエンタイトルメントファイルだけでは権限を得られません。
- 署名済みアプリやプロビジョニングプロファイルは含めていません。iPad版は開発用にXcodeから入れます。
- iPadはUSBトンネル用にTCPポート41027で待ち受けます。iPadのローカルネットワークからも到達できる可能性があります。独自の認証や暗号化は追加していません。信頼できるネットワークと端末で使用してください。ネットワークの分離やペアリングは未実装です。
- iPadの音量ボタンは音量値の変化と`MPVolumeView`で検出します。押下後と接続終了時にiPad音量を戻します。iPadOS更新後は再確認が必要です。

## ソースからビルド

macOS 27.2とiPadOSのSDKを備えたXcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、Apple Developerのチームと開発用権限が必要です。[DriverKit権限の申請方法](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)を参照してください。MacホストのApp IDにはHID Virtual DeviceとSystem Extension、DriverKit用App IDにはDriverKit・HID EventService・Transport HIDの権限が必要です。iPad版のApp IDも登録してください。

同梱するプロジェクトの`com.example.wiredpad`は署名に使わない仮IDです。共通ビルド設定`WIREPAD_BUNDLE_PREFIX`へ自分が管理する接頭辞（例: `com.yourname.wiredpad`）を指定すると、Mac・iPad・DriverKitのIDがそれぞれ`<prefix>.WiredPadMac`、`<prefix>.WiredPadPad`、`<prefix>.WiredPadTouchDriver`になります。個人のApp IDをリポジトリに書く必要はありません。登録済みIDに独自の接尾辞がある場合、ビルドスクリプトへ`WIREPAD_HOST_BUNDLE_ID`と`WIREPAD_DRIVER_BUNDLE_ID`を渡せます。ホストとドライバでは`WiredPadMac`と`WiredPadTouchDriver`より後の接尾辞を一致させてください。

1. `xcodegen generate --spec project.yml`と`xcodegen generate --spec DriverKitPrototype/project.yml`でXcodeプロジェクトを生成します。署名なしビルドや参照用の汎用プロジェクトも同梱しています。
2. 自分の署名設定でMacアプリとドライバをビルドします。

   ```sh
   export WIREPAD_BUNDLE_PREFIX=com.yourname.wiredpad
   export WIREPAD_TEAM_ID=YOUR_TEAM_ID
   export WIREPAD_DRIVER_PROFILE='Your DriverKit Development Profile'
   export WIREPAD_HOST_PROFILE='Your Mac Host Development Profile'
   export WIREPAD_SIGNING_IDENTITY='Apple Development: Your Name (TEAM_ID)'
   ./DriverKitPrototype/build-bundled-app.sh
   ```

3. `WiredPad.xcodeproj`で`WiredPadPad`スキームと接続したiPadを選び、ビルド設定の`CODE_SIGNING_ALLOWED=YES`、自分のTeam、Mac版と同じ`WIREPAD_BUNDLE_PREFIX`を設定して実行します。iPadの登録済みIDに独自の接尾辞がある場合だけ`PRODUCT_BUNDLE_IDENTIFIER`をそのIDで上書きします。Xcodeが求めたらiPadの開発者モードを有効にします。
4. スクリプトが表示した署名済みMacアプリを開き、初回だけ「診断と設定」からタッチドライバを有効にします。必要ならシステム設定で承認してください。iPadアプリを開いてUSB接続し、「このコンピュータを信頼」を許可します。Macアプリが自動で接続します。画面収録を求められたら許可します。

Appleアカウント不要のコンパイル確認:

```sh
xcodebuild -project WiredPad.xcodeproj -scheme WiredPadMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project WiredPad.xcodeproj -scheme WiredPadPad -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project DriverKitPrototype/WiredPadDriverPrototype.xcodeproj -scheme WiredPadTouchDriver -destination 'generic/platform=DriverKit' CODE_SIGNING_ALLOWED=NO build
```

## 仕組み

Mac側が仮想ディスプレイを作り、その画面だけをScreenCaptureKitで取得します。VideoToolboxで圧縮した映像を`usbmuxd`のUSBトンネルで送り、iPad側が復号・表示します。iPadは同じ接続でタッチ位置と音量操作を返します。CoreHIDの仮想タッチ機器とConsumer Control機器を作り、DriverKit拡張がタッチイベントを仮想画面UUIDに関連付けます。

[DriverKitの詳細](DriverKitPrototype/README.md)と[Sidecar入力経路の調査記録](SIDECAR_ANALYSIS.md)も参照できます。調査記録は観測結果であり、Appleが保証するAPI仕様ではありません。

## ライセンス

[MIT](LICENSE)。Appleのフレームワーク、SDK、システムコンポーネントは含みません。
