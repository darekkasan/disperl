# Entitlements / SKU / Subscriptions

Bot の収益化（プレミアム機能・サブスクリプション）に関する API を扱います。
アプリ（Bot）のトークンで呼べます。

## 目次

- [Entitlement](#entitlement)
- [SKU](#sku)
- [Subscription](#subscription)
- [Disperl::Entitlement](#disperlentitlement)
- [関連ページ](#関連ページ)

## Entitlement

ユーザー / ギルドが持つ購入・特典の権利です。

```perl
# 一覧（絞り込み可）
my $list = $client->get_entitlements($app_id,
    user_id       => $user_id,
    guild_id      => $guild_id,
    sku_ids       => [ $sku_id ],
    exclude_ended => 1,
    limit         => 100,
);

my $one = $client->get_entitlement($app_id, $entitlement_id);

# 消費型（CONSUMABLE）を使う
$client->consume_entitlement($app_id, $entitlement_id);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_entitlements($app_id, %opts)` | 配列 | `user_id` / `guild_id` / `sku_ids` / `before` / `after` / `exclude_ended` / `limit` |
| `get_entitlement($app_id, $id)` | ハッシュ | 1 件取得 |
| `consume_entitlement($app_id, $id)` | `1` | 消費型を使う |

- `limit` は 1〜100
- `sku_ids` は配列（カンマ区切りで送信）

### テスト用 Entitlement

課金フローを試すためのテスト Entitlement を作れます。

```perl
my $test = $client->create_test_entitlement($app_id,
    sku_id     => $sku_id,
    owner_id   => $user_id,
    owner_type => 'user_subscription',    # guild_subscription / user_subscription
);

$client->delete_test_entitlement($app_id, $test->{id});
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `create_test_entitlement($app_id, %opts)` | ハッシュ | `sku_id` / `owner_id` / `owner_type` |
| `delete_test_entitlement($app_id, $id)` | `1` | テスト用を削除 |

- `owner_type` の既定は `user_subscription`
- 本番の Entitlement ではなく、テスト用として扱われます

## SKU

販売単位です。一覧は取得のみできます。

```perl
my $skus = $client->get_skus($app_id);
for my $sku (@$skus) {
    print "$sku->{id} $sku->{name} (type: $sku->{type})\n";
}
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_skus($app_id)` | 配列 | SKU 一覧 |

## Subscription

SKU に紐づくサブスクリプションの一覧（Bot 自身が発行したもの）です。

```perl
my $subs = $client->get_sku_subscriptions($sku_id,
    user_id => $user_id,
    limit   => 100,
);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_sku_subscriptions($sku_id, %opts)` | 配列 | `user_id` / `before` / `after` / `limit` |

## Disperl::Entitlement

Entitlement / SKU の種別を名前⇔数値で変換します。

```perl
use Disperl::Entitlement qw(
    entitlement_owner_map entitlement_owner_name entitlement_owner_value
    sku_type_map sku_type_name sku_type_value
);

entitlement_owner_value('guild_subscription');   # 1
sku_type_value('subscription');                  # 3
```

| 所有者種別 | 値 | SKU 種別 | 値 |
|---|---|---|---|
| `GUILD_SUBSCRIPTION` | 1 | `DURABLE` | 1 |
| `USER_SUBSCRIPTION` | 2 | `CONSUMABLE` | 2 |
| | | `SUBSCRIPTION` | 3 |
| | | `SUBSCRIPTION_GROUP` | 4 |

## 関連ページ

- [アプリ情報 / コマンド権限 / widget](applications.md)
- [Client](client.md)
- [制限値の一覧](limits.md)
- [CLI](cli.md)
