package workflows.server;

class Constants
{
	inline public static var SERVER_PORT = 4000;

	inline public static var SERVER_API_URL = '/api';
	inline public static var SERVER_API_RPC_URL_FRAGMENT = '/rpc';
	inline public static var SERVER_RPC_URL = '${SERVER_API_URL}${SERVER_API_RPC_URL_FRAGMENT}';
	public static var SERVER_LOCAL_HOST :Host = new Host(new HostName('localhost'), new Port(SERVER_PORT));
	public static var SERVER_LOCAL_RPC_URL :UrlString = 'http://${SERVER_LOCAL_HOST}${SERVER_RPC_URL}';

	public static var MULTIPART_API_WORKFLOW_RUN = '/workflow/run';
}