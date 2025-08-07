import anyio
from mcp.client.sse import sse_client
from mcp.client.session import ClientSession
import logging

# --- Configuration ---
# This should match the port your server.py is running on.
# FastMCP defaults to 6288 if not specified.
PORT = 6288
SERVER_URL = f"http://127.0.0.1:{PORT}/sse"
SAMPLE_QUERY = "What are the main attractions in Rome?"

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

async def main():
    """
    Connects to the Watsonx Chat Agent server and calls its `chat` tool.
    """
    logging.info(f"Connecting to Watsonx agent at {SERVER_URL}...")

    try:
        # 1) Open the SSE transport to the server
        async with sse_client(SERVER_URL) as (read_stream, write_stream):
            
            # 2) Start the MCP session
            async with ClientSession(read_stream, write_stream) as session:
                
                # 3) Handshake with the server
                await session.initialize()
                logging.info("Session initialized successfully.")

                # 4) Call the 'chat' tool with the sample query
                logging.info(f"Invoking chat(query='{SAMPLE_QUERY}')...")
                try:
                    # Use session.call_tool to interact with the server's tool
                    result = await session.call_tool("chat", {"query": SAMPLE_QUERY})

                    # The response text is in the 'content' attribute of the result object
                    if result and not result.isError and result.content and result.content[0].text:
                        response_text = result.content[0].text
                        logging.info("Received response from Watsonx:")
                        print(f"\n---\n{response_text}\n---\n")
                    else:
                        logging.warning("Received an empty or error response from the tool.")
                        logging.warning(f"Full response object: {result}")

                except Exception as e:
                    logging.error(f"An error occurred while calling the 'chat' tool: {e}")

    except anyio.exceptions.ConnectError:
        logging.error(f"Connection failed. Is the server.py script running on port {PORT}?")
    except Exception as e:
        logging.error(f"An unexpected error occurred: {e}")


if __name__ == "__main__":
    anyio.run(main)