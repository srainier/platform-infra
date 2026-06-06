import pulumi
import pulumi_digitalocean as do


def create_postgres(
    region: str,
    version: str,
    size: str,
    vpc_id: pulumi.Input[str],
    trusted_app_ids: list[str],
) -> tuple[do.DatabaseCluster, do.DatabaseConnectionPool]:
    cluster = do.DatabaseCluster(
        "platform-postgres",
        name="platform-postgres",
        engine="pg",
        version=version,
        size=size,
        region=region,
        node_count=1,
        private_network_uuid=vpc_id,
    )

    # Trusted sources are declarative and exclusive: list every source that may
    # reach the cluster. App Platform apps are NOT VPC members, so each app must
    # be named here by UUID (managed via the trusted_app_ids config). Omitting an
    # app here locks it out on the next `pulumi up`.
    firewall_rules = [
        do.DatabaseFirewallRuleArgs(type="ip_addr", value="10.10.0.0/16"),
    ]
    firewall_rules += [
        do.DatabaseFirewallRuleArgs(type="app", value=app_id)
        for app_id in trusted_app_ids
    ]
    do.DatabaseFirewall(
        "platform-postgres-firewall",
        cluster_id=cluster.id,
        rules=firewall_rules,
    )

    pool = do.DatabaseConnectionPool(
        "platform-postgres-pool",
        cluster_id=cluster.id,
        name="platform-pool",
        mode="transaction",
        size=10,
        db_name="defaultdb",
        user="doadmin",
    )

    return cluster, pool
