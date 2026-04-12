import pulumi
import pulumi_digitalocean as do


def create_postgres(
    region: str,
    version: str,
    size: str,
    vpc_id: pulumi.Input[str],
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

    do.DatabaseFirewall(
        "platform-postgres-firewall",
        cluster_id=cluster.id,
        rules=[do.DatabaseFirewallRuleArgs(type="ip_addr", value="10.10.0.0/16")],
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
