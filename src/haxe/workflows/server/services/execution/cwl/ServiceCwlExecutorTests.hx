package workflows.server.services.execution.cwl;

import haxe.remoting.JsonRpc;
import t9.js.jsonrpc.Routes;

import js.node.Fs;
import js.node.stream.Readable;
import js.node.Http;
import js.node.http.*;
import js.npm.docker.Docker;
import js.npm.busboy.Busboy;
import js.npm.shortid.ShortId;
import js.npm.fsextended.FsExtended;
import js.npm.streamifier.Streamifier;

class ServiceCwlExecutorTests
{
	@timeout(120000)
	public static function testMultipartRPCSubmission() :Promise<Bool>
	{
		var url = 'http://localhost:${SERVER_PORT}${MULTIPART_API_WORKFLOW_RUN}';

		var cwl = FsExtended.readFileSync('test/example_workflows/multistep/multistep.cwl');
		var run = FsExtended.readFileSync('test/example_workflows/multistep/multistep-run.yml');

		var formData :DynamicAccess<Dynamic> = {};
		formData[ServiceCwlExecutor.CWL] = cwl;
		formData[ServiceCwlExecutor.JOB_YAML] = run;
		for (file in ['hello.tar', 'arguments.cwl', 'tar-param.cwl']) {
			formData[file] = Fs.createReadStream('test/example_workflows/multistep/$file');
		}

		var promise = new DeferredPromise();
		js.npm.request.Request.post({url:url, formData: formData},
			function(err, httpResponse, body) {
				if (err != null) {
					promise.boundPromise.reject(err);
					return;
				}
				traceYellow('httpResponse.statusCode=${httpResponse.statusCode}');
				traceYellow('body=${body}');
				if (httpResponse.statusCode == 200) {
					try {
						promise.resolve(true);
					} catch (err :Dynamic) {
						promise.boundPromise.reject(err);
					}
				} else {
					promise.boundPromise.reject('non-200 response body=' + body);
				}
			});

		return promise.boundPromise;
	}
}

