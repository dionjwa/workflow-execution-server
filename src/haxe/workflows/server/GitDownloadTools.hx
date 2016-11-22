package workflows.server;

import js.node.Path;
import js.npm.fsextended.FsExtended;

class GitDownloadTools
{
	public static function getGithubUrl(basePath :String, githubUrl :String) :Promise<String>
	{
		var targetPath = Path.join(basePath, pathifyGithubString(githubUrl));

		if (FsExtended.existsSync(targetPath)) {
			return Promise.promise(targetPath);
		}

		if (PATH_DOWNLOADS.exists(targetPath)) {
			return PATH_DOWNLOADS.get(targetPath);
		}

		var tmpId = Node.require('shortid').generate();
		var tempPath = '/tmp/$tmpId';

		var promise = new DeferredPromise();
		PATH_DOWNLOADS.set(targetPath, promise.boundPromise);
		promise.catchError(function(err) {
			trace(err);
			PATH_DOWNLOADS.remove(targetPath);
			try {
				FsExtended.rmdirSync(tempPath);
			} catch (err :Dynamic){}
			try {
				FsExtended.rmdirSync(targetPath);
			} catch (err :Dynamic){}
			throw err;
		});

		var ghdownload :String->String->js.node.events.EventEmitter<Dynamic> = Node.require('github-download');
		var emitter = ghdownload(githubUrl, tempPath);
		emitter.on('error', function(err) {
			promise.boundPromise.reject(err);
			trace(err);
		});
		emitter.on('end', function(err) {
			trace('Successful download $targetPath');
			FsExtended.ensureDirSync(targetPath);
			FsExtended.copyDirSync(tempPath, targetPath);
			trace('Successful copyDirSync $tempPath $targetPath');
			promise.resolve(targetPath);
		});

		return promise.boundPromise;
	}

	static function pathifyGithubString(path :String) :String
	{
		return path.replace('https://', '').replace('http://', '');
	}

	static var PATH_DOWNLOADS = new Map<String, Promise<String>>();
}