# Heartecho

[English](../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

Heartecho は、仮想オーディオデバイスの作成、アプリまたはハードウェア入力から出力チャンネルへのルーティング、レベル監視、Core Audio HAL ドライバ関連コンポーネントのパッケージ化を行うネイティブ macOS オーディオルーティング作業環境です。

製品の方向性は Rogue Amoeba Loopback のようなツールに近いものですが、このリポジトリはまだエンジニアリングプレビューです。SwiftUI アプリ、ルーティングモデル、診断、Helper ランタイム、インストーラスクリプト、C HAL ドライバの骨組みはありますが、正式配布には Developer ID 署名、公証、インストール済みドライバの完全な検証が必要です。

## 製品概要

- ネイティブ macOS SwiftUI/AppKit によるルーティンググラフ設定アプリ。
- 仮想デバイス、音声ソース、チャンネルマップ、モニター、ゲイン、ミュート、プリセット、グラフ検証の中核モデル。
- アプリ音声タップ、ハードウェア入力キャプチャ、サンプルレート変換、モニター再生、メーター、HAL 共有メモリ公開のランタイム足場。
- C HAL Audio Server Driver の骨組み、Swift ブリッジ、bundle 生成、検証、インストール、アンインストール、診断スクリプト。
- app bundle、HAL driver bundle、Helper LaunchAgent、インストーラ、アンインストーラ、distribution package、JSON release manifest のリリースパイプライン。

詳細な実装メモは [architecture.md](architecture.md)、[feature-map.md](feature-map.md)、[hal-driver.md](hal-driver.md)、[implementation-plan.md](implementation-plan.md) を参照してください。

## 必要環境

- macOS 14 以降。
- Swift 6 ツールチェーン。
- リリースビルド、署名、パッケージング、HAL ドライバ作業には Xcode 16 以降を推奨します。一部のローカル SwiftPM 開発タスクは Command Line Tools だけでも実行できます。
- アイコン生成には Python と Pillow が必要です。GitHub Actions workflow はローカル仮想環境を自動作成します。

## クイックスタート

アプリを実行します。

```sh
swift run Heartecho
```

システムを変更しない診断を実行します。

```sh
CLANG_MODULE_CACHE_PATH=.build/clang-module-cache \
swift run --disable-sandbox HeartechoDiagnostics --skip-shared-memory
```

ローカル app bundle をビルドして検証します。

```sh
scripts/build-icons.sh
scripts/build-app-bundle.sh debug
scripts/verify-app-bundle.sh
```

ローカルで release artifacts を作成します。

```sh
scripts/build-release-artifacts.sh --configuration release
```

release artifact コマンドはパッケージを `build/pkg/` に、release manifest を `build/release-manifest.json` に書き込みます。

## GitHub Release 自動化

`VERSION` が GitHub Release のバージョン情報の唯一の情報源です。[release.yml](../.github/workflows/release.yml) は `main` への push と手動 dispatch で実行されます。

release job は現在 `macos-15` で実行され、Xcode 16.4 を明示的に選択します。これにより [Package.swift](../Package.swift) の Swift 6 tools version をサポートできます。runner が古い Swift ツールチェーンに戻った場合、`scripts/check-swift-toolchain.sh` が早い段階で読みやすいエラーを出します。

正常に完了すると workflow は次を行います。

1. `VERSION` を読み取る。
2. Python のアイコンビルド依存関係をインストールする。
3. app、HAL driver、installer、uninstaller、distribution package、manifest をビルドする。
4. `v$(cat VERSION)` がなければ Release を作成し、既にあれば `--clobber` で assets を更新する。

GitHub CLI 認証後のローカル公開:

```sh
scripts/build-release-artifacts.sh --configuration release
scripts/publish-github-release.sh
```

## システム統合

Heartecho は通常のサンドボックスアプリだけでは Loopback 相当の製品にはなりません。仮想デバイスには、Core Audio HAL Audio Server Driver をシステムまたはユーザーのプラグイン場所にインストールする必要があります。アプリ単位のキャプチャには macOS process taps とユーザーが許可した音声キャプチャ権限が必要です。ハードウェア入力キャプチャにはマイク権限が必要です。

まず dry run としてインストール、アンインストール、検証、復旧スクリプトを使ってください。

```sh
scripts/install-heartecho.sh --wait 30
scripts/uninstall-heartecho.sh --unload-helper --reload-core-audio
scripts/validate-installation.sh --wait 30
scripts/validate-installed-audio.sh --iterations 3 --wait 30
```

署名、公証、インストール場所、ローカルシステムへの影響を理解してから `--execute` を追加してください。

## プロジェクト構成

- `Sources/HeartechoApp`: ネイティブ設定および監視アプリ。
- `Sources/HeartechoCore`: 製品モデル、プリセット、永続化、ルーティンググラフ検証。
- `Sources/HeartechoAudio`: デバイス検出、キャプチャ足場、ルーティングランタイム、ミキサー、モニター再生、HAL 公開、診断ヘルパー。
- `Sources/HeartechoHelper`: ルーティンググラフ初期化と HAL 設定/音声公開を行うコマンドライン Helper。
- `Sources/HALDriverStub` と `Sources/HALDriverC`: Swift ブリッジと C HAL ドライバ骨組み。
- `scripts`: ビルド、検証、署名、公証、インストール、アンインストール、公開、復旧の自動化。
- `docs`: アーキテクチャ、HAL、機能、実装計画の文書。

## メンテナンス方針

ルート README は製品入口として保ち、詳細なエンジニアリングメモは `docs/` に置きます。リリース動作はスクリプトに集約し、ユーザー向けの製品挙動が変わったときは英語・中国語・日本語 README を同時に更新します。
