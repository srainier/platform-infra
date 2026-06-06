import pulumi
import pulumi_digitalocean as do


def create_valkey(
    region: str,
    size: str,
    vpc_id: pulumi.Input[str],
    trusted_app_ids: list[str],
) -> do.DatabaseCluster:
    # DigitalOcean replaced Managed Redis with Managed Valkey (Redis-compatible
    # Linux Foundation fork) as of mid-2025. Apps connect using standard Redis
    # clients — the wire protocol and connection interface are identical.
    cluster = do.DatabaseCluster(
        "platform-valkey",
        name="platform-valkey",
        engine="valkey",
        version="8",
        size=size,
        region=region,
        node_count=1,
        private_network_uuid=vpc_id,
    )

    firewall_rules = [
        do.DatabaseFirewallRuleArgs(type="ip_addr", value="10.10.0.0/16"),
    ]
    firewall_rules += [
        do.DatabaseFirewallRuleArgs(type="app", value=app_id)
        for app_id in trusted_app_ids
    ]
    do.DatabaseFirewall(
        "platform-valkey-firewall",
        cluster_id=cluster.id,
        rules=firewall_rules,
    )

    return cluster
