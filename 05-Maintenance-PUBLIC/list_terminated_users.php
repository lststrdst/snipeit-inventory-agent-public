#!/usr/bin/env php
<?php

declare(strict_types=1);

use App\Models\Ldap;
use App\Models\Setting;
use Illuminate\Contracts\Console\Kernel;

$appPath = $argv[1] ?? '/var/www/snipe-it';
$appPath = rtrim($appPath, '/');
$searchBase = trim((string)($argv[2] ?? ''));

try {
    require $appPath.'/vendor/autoload.php';
    $app = require $appPath.'/bootstrap/app.php';
    $app->make(Kernel::class)->bootstrap();

    if ($searchBase === '') {
        $configuredBase = (string)(Setting::getSettings()->ldap_basedn ?? '');
        $searchBase = preg_match('/(?:^|,)(DC=.*)$/i', $configuredBase, $matches)
            ? $matches[1]
            : $configuredBase;
    }
    if ($searchBase === '') {
        throw new RuntimeException('LDAP search base is empty');
    }

    $attributes = [
        'samaccountname',
        'description',
        'distinguishedname',
        'useraccountcontrol',
    ];
    $entries = Ldap::findLdapUsers(
        $searchBase,
        -1,
        '(&(objectCategory=person)(objectClass=user))',
        $attributes
    );
    if (!is_array($entries)) {
        throw new RuntimeException('LDAP query did not return an array');
    }

    $lower = static function (string $value): string {
        return function_exists('mb_strtolower')
            ? mb_strtolower($value, 'UTF-8')
            : strtolower($value);
    };

    // ASCII-safe source: decode the UTF-8 marker instead of embedding it directly.
    $terminatedNeedle = json_decode(
        '"\\u0443\\u0432\\u043e\\u043b"',
        true,
        512,
        JSON_THROW_ON_ERROR
    );
    $containsTerminatedWord = static function (string $value) use ($lower, $terminatedNeedle): bool {
        return str_contains($lower($value), $terminatedNeedle);
    };

    $users = [];
    foreach ($entries as $key => $entry) {
        if (!is_int($key) || !is_array($entry)) {
            continue;
        }
        $username = trim((string)($entry['samaccountname'][0] ?? ''));
        if ($username === '') {
            continue;
        }

        $description = trim((string)($entry['description'][0] ?? ''));
        $dn = trim((string)($entry['distinguishedname'][0] ?? ($entry['dn'] ?? '')));
        $userAccountControl = (int)($entry['useraccountcontrol'][0] ?? 0);
        $disabled = ($userAccountControl & 2) === 2;
        $descriptionMatched = $containsTerminatedWord($description);
        $ouMatched = false;

        if ($dn !== '' && preg_match_all('/(?:^|,)OU=([^,]+)/iu', $dn, $matches)) {
            foreach ($matches[1] as $ouName) {
                if ($containsTerminatedWord((string)$ouName)) {
                    $ouMatched = true;
                    break;
                }
            }
        }

        // Disabled in AD is authoritative. Description and OU only explain why.
        if (!$disabled) {
            continue;
        }

        $reasons = [];
        if ($disabled) {
            $reasons[] = 'ad_disabled';
        }
        if ($descriptionMatched) {
            $reasons[] = 'ad_description_terminated';
        }
        if ($ouMatched) {
            $reasons[] = 'ad_ou_terminated';
        }
        $users[] = [
            'username' => $username,
            'distinguished_name' => $dn,
            'description' => $description,
            'disabled' => $disabled,
            'reason' => implode('+', $reasons),
        ];
    }

    usort(
        $users,
        static fn(array $a, array $b): int => strcasecmp($a['username'], $b['username'])
    );
    echo json_encode(
        ['schema_version' => 1, 'count' => count($users), 'users' => $users],
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
    ).PHP_EOL;
} catch (Throwable $exception) {
    fwrite(STDERR, 'LDAP helper failed: '.$exception->getMessage().PHP_EOL);
    exit(1);
}
