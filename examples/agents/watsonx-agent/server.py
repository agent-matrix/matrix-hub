# server.py  – lenient Watsonx agent
import os, logging
from typing import Union
from dotenv import load_dotenv

from mcp.server.fastmcp import FastMCP
from ibm_watsonx_ai import APIClient, Credentials
from ibm_watsonx_ai.foundation_models import ModelInference
from ibm_watsonx_ai.metanames import GenTextParamsMetaNames as GenParams

# ─── Load env vars ───────────────────────────────────────────────
load_dotenv()
API_KEY    = os.getenv("WATSONX_API_KEY")
URL        = os.getenv("WATSONX_URL")
PROJECT_ID = os.getenv("WATSONX_PROJECT_ID")
MODEL_ID   = os.getenv("MODEL_ID", "ibm/granite-3-3-8b-instruct")
PORT       = int(os.getenv("WATSONX_AGENT_PORT", 6288))

for name, val in [("WATSONX_API_KEY", API_KEY),
                  ("WATSONX_URL",     URL),
                  ("PROJECT_ID",      PROJECT_ID)]:
    if not val:
        raise RuntimeError(f"{name} is not set")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

creds  = Credentials(url=URL, api_key=API_KEY)
client = APIClient(credentials=creds, project_id=PROJECT_ID)
model  = ModelInference(model_id=MODEL_ID,
                        credentials=creds,
                        project_id=PROJECT_ID)

# ─── Define MCP server ───────────────────────────────────────────
mcp = FastMCP("Watsonx Chat Agent", port=PORT)

@mcp.tool(description="Chat with IBM watsonx.ai (accepts str or int)")
def chat(query: Union[str, int]) -> str:
    # Coerce to string so int → str
    query = str(query).strip()
    # Substitute a real prompt if UI sent the placeholder 0
    if query == "0":
        query = "What is the capital of Italy?"

    logging.info("chat() got %r", query)

    params = {
        GenParams.DECODING_METHOD: "greedy",
        GenParams.MAX_NEW_TOKENS:   200,
    }
    resp  = model.generate_text(prompt=query, params=params, raw_response=True)
    reply = resp["results"][0]["generated_text"].strip()
    logging.info("→ %r", reply)
    return reply

# ─── Run ─────────────────────────────────────────────────────────
if __name__ == "__main__":
    logging.info(f"Starting Watsonx MCP server at http://127.0.0.1:{PORT}/sse")
    mcp.run(transport="sse")   # SSE endpoint is /sse