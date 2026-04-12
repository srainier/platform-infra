import pulumi_digitalocean as do


def create_vpc(region: str) -> do.Vpc:
    return do.Vpc(
        "platform-vpc",
        name="platform-vpc",
        region=region,
        ip_range="10.10.0.0/16",
    )


def create_project() -> do.Project:
    return do.Project(
        "platform-project",
        name="platform",
        description="Shared platform infrastructure",
        purpose="Web Application",
        environment="Production",
    )


def assign_project_resources(
    project: do.Project,
    pg_cluster: do.DatabaseCluster,
    valkey_cluster: do.DatabaseCluster,
) -> do.ProjectResources:
    # VPCs are not assignable to DO Projects; databases are.
    # URN format expected by the DO Projects API: do:dbaas:{cluster_id}
    return do.ProjectResources(
        "platform-project-resources",
        project=project.id,
        resources=[
            pg_cluster.id.apply(lambda cid: f"do:dbaas:{cid}"),
            valkey_cluster.id.apply(lambda cid: f"do:dbaas:{cid}"),
        ],
    )
