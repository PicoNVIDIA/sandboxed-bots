"""peer-messaging plugin — lets a bot message a teammate bot directly."""

import logging

from . import schemas, tools

logger = logging.getLogger(__name__)


def register(ctx):
    """Wire the peer-messaging tools into the registry."""
    ctx.register_tool(
        name="message_teammate",
        toolset="peer_messaging",
        schema=schemas.MESSAGE_TEAMMATE,
        handler=tools.message_teammate,
    )
    ctx.register_tool(
        name="list_teammates",
        toolset="peer_messaging",
        schema=schemas.LIST_TEAMMATES,
        handler=tools.list_teammates,
    )
    logger.info("peer-messaging: registered message_teammate, list_teammates")
