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
