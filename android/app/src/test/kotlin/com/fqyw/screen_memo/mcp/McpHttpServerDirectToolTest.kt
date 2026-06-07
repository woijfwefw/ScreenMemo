package com.fqyw.screen_memo.mcp

import android.content.Context
import io.mockk.every
import io.mockk.mockk
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.charset.StandardCharsets

class McpHttpServerDirectToolTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var context: Context

    @Before
    fun setUp() {
        context = mockk(relaxed = true)
        every { context.applicationContext } returns context
        every { context.filesDir } returns temp.root
        every { context.getDatabasePath(any()) } answers {
            File(temp.root, firstArg<String>())
        }
    }

    @Test
    fun directToolMethod_dispatchesToRegisteredTool() {
        val server = McpHttpServer(context, port = 0) { "token" }
        val response = invokeJsonRpc(
            server,
            """
            {
              "jsonrpc": "2.0",
              "id": 1,
              "method": "screenmemo_status",
              "params": {}
            }
            """.trimIndent(),
        )

        assertFalse(response.has("error"))
        val result = response.getJSONObject("result")
        assertFalse(result.getBoolean("isError"))
        assertTrue(result.getJSONObject("structuredContent").has("service"))
        assertTrue(result.getJSONObject("structuredContent").has("database"))
    }

    @Test
    fun unknownMethod_stillReturnsMethodNotFound() {
        val server = McpHttpServer(context, port = 0) { "token" }
        val response = invokeJsonRpc(
            server,
            """
            {
              "jsonrpc": "2.0",
              "id": 2,
              "method": "not_a_screenmemo_tool",
              "params": {}
            }
            """.trimIndent(),
        )

        val error = response.getJSONObject("error")
        assertEquals(-32601, error.getInt("code"))
        assertEquals("Method not found", error.getString("message"))
    }

    private fun invokeJsonRpc(server: McpHttpServer, body: String): JSONObject {
        val method = McpHttpServer::class.java.getDeclaredMethod(
            "handleJsonRpcBody",
            ByteArray::class.java,
        )
        method.isAccessible = true
        val httpResponse = method.invoke(server, body.toByteArray(StandardCharsets.UTF_8))
        val bodyField = httpResponse.javaClass.getDeclaredField("body")
        bodyField.isAccessible = true
        val responseBody = bodyField.get(httpResponse) as ByteArray
        return JSONObject(responseBody.toString(StandardCharsets.UTF_8))
    }
}
