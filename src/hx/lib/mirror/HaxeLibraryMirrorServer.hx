package hx.lib.mirror;

import js.Node;
import logging.ILogger;
import logging.handlers.NodeHandler;
import logging.Logging.getLogger;

class Router
{
    var request:NodeHttpServerReq;
    var response:NodeHttpServerResp;
    var url:NodeUrlObj;
    var http:NodeHttp;
    var fs:NodeFS;
    var logger:ILogger;

    static var mUrl:NodeUrl;

    public function new(request, response)
    {
        this.request = request;
        this.response = response;
        this.url = urlParse(request.url);

        this.http = Node.require("http");
        this.fs   = Node.fs;
    }

    static public function __init__()
    {
        mUrl = Node.url;
    }

    static public function urlParse(anUrl:String):NodeUrlObj
    {
        return mUrl.parse(anUrl);
    }
}

class RouterProxy extends Router
{
    public function new(request, response)
    {
        super(request, response);
        logger = getLogger("hx.lib.mirror.RouterProxy");

        var proxy_url:String = url.pathname;
        if (null != url.search)
            proxy_url += url.search;

        var request_options:NodeHttpReqOpt = {
            host: url.host,
            port: 80,
            path: proxy_url,
            method: request.method,
            headers: request.headers,
        };

        logger.debug("代理请求 " + request.url);

        var request_official:NodeHttpClientReq = http.request(request_options,
            onProxyResponse);
        request.pipe(request_official);
    }

    function onProxyResponse(proxyResponse:NodeHttpClientResp):Void
    {
        proxyResponse.pipe(response);
    }
}

class RouterArchive extends Router
{
    var target:String;
    var target_lock:String;

    public function new(request, response)
    {
        super(request, response);
        logger = getLogger("hx.lib.mirror.RouterArchive");

        target = url.pathname.substr(1);
        target_lock = target + ".lock";

        fs.exists(target_lock, onHasCacheLockFile);
    }

    function onHasCacheLockFile(lock:Bool)
    {
        if (lock)
            new RouterProxy(request, response);
        else
            fs.exists(target, onHasCacheFile);
    }

    function onHasCacheFile(has:Bool)
    {
        if (has) {
            sendCacheFile();
        } else {
            saveAndSendFile();
        }
    }

    function sendCacheFile()
    {
        logger.debug("从磁盘响应文件请求 $file", {file: target});
        fs.stat(target, function(error, stat) {
            response.writeHead(200, {
                'context-length': stat.size
            });
            fs.createReadStream(target).pipe(response);
        });
    }

    function saveAndSendFile()
    {
        fs.writeFile(target_lock, "lock", lockedCacheFile);
    }

    function lockedCacheFile(error:NodeErr)
    {
        if (null == error) {
            logger.debug('请求远程文件。');
            http.get(Router.urlParse(request.url), onArchiveResponse);
        }
    }

    function onArchiveResponse(archiveResponse:NodeHttpClientResp)
    {
        response.writeHead(archiveResponse.statusCode, archiveResponse.headers);
        archiveResponse.pipe(response);

        var archiveFile = fs.createWriteStream(target);
        archiveResponse.pipe(archiveFile);
        archiveFile.on('close', onCachedFile);
    }

    function onCachedFile()
    {
        logger.debug("文件缓存完毕。")
        fs.unlink(target_lock, function(error) {
            if (null != error)
                logger.error(error);
            logger.debug('删除锁文件' + target_lock);
        });
    }
}

class HaxeLibraryMirrorServer
{
    

    public function new()
    {
    }

    static function onCreateServer(req:NodeHttpServerReq, 
        res:NodeHttpServerResp)
    {
        var url = Router.urlParse(req.url);
        getLogger("").debug(url.pathname);
        var is_download_file = url.pathname.indexOf("/files/") == 0;

        if (!is_download_file)
            new RouterProxy(req, res);
        else
            new RouterArchive(req, res);
    }

    static function onMkDir(error:NodeErr)
    {

    }

    static public function main()
    {
        getLogger("").addHandler(new NodeHandler());

        Node.fs.mkdir("files", 0777, onMkDir);
        Node.fs.mkdir("files/3.0", 0777, onMkDir);

        var logger:ILogger = getLogger("hx.lib.mirror.HaxeLibraryMirrorServer");
        logger.debug("Started server.");

        var server = Node.http.createServer(onCreateServer);
        server.listen(3000,"0.0.0.0");

    }
}