#!/usr/bin/env python3
import re, subprocess, tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=(root/'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt').read_text()
m=re.search(r'private const val VENERA_BOOTSTRAP = """\n(.*?)\n"""', source, re.S)
if not m: raise SystemExit('VENERA_BOOTSTRAP not found')
bootstrap=m.group(1)
test=r'''
globalThis.ZicNative={request(){throw new Error('native bridge unexpectedly used')},complete(){},finished(){},activated(){}};
async function checkCurrentCategory(){
 let seen=null;
 globalThis.__zicSource={
   category:{itemType:'category',parts:[{categories:['最新','热门'],categoryParams:['new','hot']}]},
   categoryComics:{
     optionLoader:async(category,param)=>[{options:[{value:'all'}],default:'all'}],
     load:async(category,param,options,page)=>{seen={category,param,options,page};return {comics:[{id:'1',title:'Current'}],maxPage:2}}
   }
 };
 const sections=await __zicOperation({operation:'loadBrowseSections',arguments:{}});
 if(sections.length!==2||sections[0].label!=='最新'||sections[1].label!=='热门')throw new Error('current category sections '+JSON.stringify(sections));
 const value=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20,sectionId:sections[0].sectionId}});
 if(value.items.length!==1||value.items[0].title!=='Current')throw new Error('current category result failed');
 if(JSON.stringify(seen)!==JSON.stringify({category:'最新',param:'new',options:['all'],page:1}))throw new Error('current category arguments '+JSON.stringify(seen));
 seen=null;
 await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20,sectionId:sections[1].sectionId}});
 if(JSON.stringify(seen)!==JSON.stringify({category:'热门',param:'hot',options:['all'],page:1}))throw new Error('selected category arguments '+JSON.stringify(seen));
}
async function checkLegacyCategory(){
 let seen=null;
 globalThis.__zicSource={category:{parts:[{categories:[{target:{page:'category',attributes:{category:'legacy',param:'p'}}}]}]},categoryComics:{optionList:[{options:['x-y']}],load:async(...args)=>{seen=args;return [{id:'2',title:'Legacy'}]}}};
 const value=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20}});
 if(value.items[0].title!=='Legacy'||seen[0]!=='legacy'||seen[1]!=='p'||seen[2][0]!=='x')throw new Error('legacy category failed');
}
async function checkExploreObject(){
 globalThis.__zicSource={explore:{home:{load:async page=>({sections:new Map([['a',[{id:'3',title:'Explore'}]]]),maxPage:page})}}};
 const value=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20}});
 if(value.items[0].title!=='Explore')throw new Error('explore object failed');
}
async function checkLoadNextExplore(){
 const calls=[];
 globalThis.__zicSource={
   url:'https://e.invalid/source.js',
   comic:{},
   explore:[{title:'latest',loadNext:async next=>{calls.push(next);return next===null?{comics:[{id:'https://e.invalid/g/1',title:'Page 1A',cover:'/cover-1.jpg'},{id:'https://e.invalid/g/1b',title:'Page 1B'}],next:'page-2'}:{comics:[{id:'https://e.invalid/g/2',title:'Page 2'}],next:null}}}]
 };
 if(!__zicHasBrowseCapability(globalThis.__zicSource))throw new Error('loadNext capability not discovered');
 const first=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:1}});
 const second=await __zicOperation({operation:'browse',arguments:{query:'',offset:1,limit:1}});
 const third=await __zicOperation({operation:'browse',arguments:{query:'',offset:2,limit:1}});
 if(first.items[0].title!=='Page 1A'||first.items[0].coverUri!=='https://e.invalid/cover-1.jpg'||!first.hasMore)throw new Error('loadNext first slice failed '+JSON.stringify(first));
 if(second.items[0].title!=='Page 1B'||!second.hasMore)throw new Error('loadNext retained slice failed '+JSON.stringify(second));
 if(third.items[0].title!=='Page 2'||third.hasMore)throw new Error('loadNext second source page failed '+JSON.stringify(third));
 if(JSON.stringify(calls)!==JSON.stringify([null,'page-2']))throw new Error('loadNext tokens '+JSON.stringify(calls));
}

async function checkSearchOptionDefaults(){
 let seen=null;
 globalThis.__zicSource={
   search:{
     optionList:[
       {type:'multi-select',options:['0-Misc','1-Doujinshi'],default:['0','1']},
       {type:'dropdown',options:['-None','5-Five']},
     ],
     loadNext:async(keyword,options,next)=>{
       seen={keyword,options,next,category:JSON.parse(options[0])};
       return {comics:[{id:'search-result',title:'Search result'}],next:null}
     }
   }
 };
 const value=await __zicOperation({operation:'browse',arguments:{query:'tag',offset:0,limit:20}});
 if(value.items[0].title!=='Search result')throw new Error('search result failed');
 if(JSON.stringify(seen)!==JSON.stringify({keyword:'tag',options:['["0","1"]',''],next:null,category:['0','1']}))throw new Error('search option defaults '+JSON.stringify(seen));
}

async function checkLegacyGlobalScratchBinding(){
 class LegacySource extends ComicSource {
   key='legacy';name='Legacy';url='https://legacy.invalid/';
   explore=[{load:async()=>[{id:'comic',title:'Legacy comic'}]}];
   comic={loadInfo:async(id)=>{res={title:'Legacy detail',chapters:{one:'One'}};return res}};
 }
 globalThis.__zicSource=new LegacySource();
 const browse=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20}});
 const detail=await __zicOperation({operation:'loadComic',arguments:{comicId:browse.items[0].comicId}});
 if(detail.comic.title!=='Legacy detail'||detail.chapters[0].title!=='One')throw new Error('legacy res binding failed '+JSON.stringify(detail));
 const detailMessage=__zicErrorMessage(new ReferenceError('boom'),'loadComic');
 if(!detailMessage.startsWith('loadComic: boom'))throw new Error('operation error context failed '+detailMessage);
}

async function checkDirectCoverResource(){
 let seen=null;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));seen=message;
   if(message.method!=='http_image_binary')throw new Error('unexpected direct cover bridge method '+message.method);
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{'content-type':'image/jpeg'},nativeBytesToken:'cover-token'})});
 };
 globalThis.__zicSource={comic:{}};
 const bytes=await __zicOperation({operation:'loadResource',arguments:{uri:'https://cdn.invalid/cover.jpg'}});
 if(bytes.__zicNativeBytesToken!=='cover-token')throw new Error('direct cover native token failed '+JSON.stringify(bytes));
 if(seen.url!=='https://cdn.invalid/cover.jpg'||seen.http_method!=='GET')throw new Error('direct cover request failed '+JSON.stringify(seen));
}

async function checkStableEntityIds(){
 const first=__zicComic({id:'https://e-hentai.org/g/1/token/',title:'Old title',subtitle:'A',cover:'https://cdn.invalid/old.jpg',description:'Old'});
 const second=__zicComic({id:'https://e-hentai.org/g/1/token/',title:'New title',subtitle:'B',cover:'https://cdn.invalid/new.jpg',description:'New'});
 if(first.comicId!==second.comicId)throw new Error('mutable Venera metadata changed comicId');
 const payload=__zicUnb64(first.comicId.slice('venera:comic:'.length));
 if(payload.v!==2||payload.id!=='https://e-hentai.org/g/1/token/'||Object.keys(payload).length!==2)throw new Error('stable comic payload includes mutable fields '+JSON.stringify(payload));
 const oldChapter=__zicChapterMessage(first.comicId,'ep-1','Old chapter title',9);
 const newChapter=__zicChapterMessage(first.comicId,'ep-1','New chapter title',1);
 if(oldChapter.chapterId!==newChapter.chapterId)throw new Error('mutable Venera chapter metadata changed chapterId');
 const chapterPayload=__zicUnb64(oldChapter.chapterId.slice('venera:chapter:'.length));
 if(chapterPayload.title!==undefined||chapterPayload.sequence!==undefined)throw new Error('stable chapter payload contains presentation metadata '+JSON.stringify(chapterPayload));
}

async function checkChapterPageCount(){
 const comicId='venera:comic:'+__zicB64({id:'comic',title:'Comic'});
 const chapter=__zicChapterMessage(comicId,'ep-1','Episode',0);
 globalThis.__zicSource={comic:{loadEp:async()=>['https://cdn.invalid/1.jpg','https://cdn.invalid/2.jpg']}};
 const value=await __zicOperation({operation:'loadChapter',arguments:{chapterId:chapter.chapterId}});
 if(value.chapter.pageCount!==2||value.pages.length!==2)throw new Error('chapter page count mismatch '+JSON.stringify(value));
}

async function checkWebpPageHints(){
 const comicId='venera:comic:'+__zicB64({id:'webp-comic',title:'WebP'});
 const chapter=__zicChapterMessage(comicId,'ep-webp','WebP episode',0);
 globalThis.__zicSource={comic:{loadEp:async()=>[
   'https://cdn.invalid/animated.webp?token=1',
   'https://cdn.invalid/static.png#fragment',
   'opaque-image-id'
 ]}};
 const value=await __zicOperation({operation:'loadChapter',arguments:{chapterId:chapter.chapterId}});
 if(value.pages[0].contentKindHint!=='webp'||value.pages[0].animatedHint!==true)throw new Error('WebP page hint missing '+JSON.stringify(value.pages[0]));
 if(value.pages[1].contentKindHint!=='png'||value.pages[1].animatedHint!==false)throw new Error('PNG page hint missing '+JSON.stringify(value.pages[1]));
 if(value.pages[2].contentKindHint!==undefined||value.pages[2].animatedHint!==undefined)throw new Error('opaque image received an invented hint '+JSON.stringify(value.pages[2]));
}

async function checkSingleVolumeChapter(){
  const comicId='venera:comic:'+__zicB64({id:'https://e-hentai.org/g/1/token/',title:'Gallery'});
  let seenEpId='not-called',infoLoads=0;
  globalThis.__zicSource={comic:{
   loadInfo:async()=>{infoLoads++;return {title:'Gallery',maxPage:24}},
   loadEp:async function(comicRawId,epId){seenEpId=epId;const info=await this.loadInfo(comicRawId);return Array.from({length:info.maxPage},(_,i)=>'https://cdn.invalid/'+i+'.jpg')}
  }};
  const detail=await __zicOperation({operation:'loadComic',arguments:{comicId}});
  if(detail.chapters.length!==1||detail.chapters[0].title!=='正文'||detail.chapters[0].pageCount!==24)throw new Error('single-volume detail failed '+JSON.stringify(detail));
  const rawChapter=__zicUnb64(detail.chapters[0].chapterId.slice('venera:chapter:'.length));
  if(rawChapter.epId!==null)throw new Error('single-volume epId was stringified '+JSON.stringify(rawChapter));
  const loaded=await __zicOperation({operation:'loadChapter',arguments:{chapterId:detail.chapters[0].chapterId}});
  if(seenEpId!==null||loaded.pages.length!==24||infoLoads!==2)throw new Error('single-volume loadEp ownership failed '+JSON.stringify({seenEpId,infoLoads,loaded}));
}

async function checkComicPreviewPagination(){
 const comicId='venera:comic:'+__zicB64({id:'comic-preview',title:'Preview'});
 const calls=[];
 globalThis.__zicSource={url:'https://source.invalid/',comic:{
   loadInfo:async()=>({title:'Preview',chapters:{one:'One'},thumbnails:['https://cdn.invalid/info-1.jpg']}),
   loadThumbnails:async(id,next)=>{calls.push(next);return next==null?{thumbnails:['/p1.jpg'],next:7}:{thumbnails:['/p2.jpg'],next:null}}
 }};
 const detail=await __zicOperation({operation:'loadComic',arguments:{comicId}});
 if(detail.preview!==null||detail.comic.title!=='Preview')throw new Error('loadThumbnails source consumed the info thumbnails '+JSON.stringify(detail));
 const first=await __zicOperation({operation:'loadComicPreview',arguments:{comicId,nextToken:null}});
 if(first.items.length!==1||first.items[0].uri!=='https://source.invalid/p1.jpg'||first.nextToken==null)throw new Error('preview first page failed '+JSON.stringify(first));
 const second=await __zicOperation({operation:'loadComicPreview',arguments:{comicId,nextToken:first.nextToken}});
 if(calls[0]!==null||calls[1]!==7||second.items[0].uri!=='https://source.invalid/p2.jpg'||second.nextToken!==null)throw new Error('preview cursor pagination failed '+JSON.stringify({calls,first,second}));
}

async function checkPreviewCropIdentity(){
 const comicId='venera:comic:'+__zicB64({id:'comic-preview-crop',title:'Preview crop'});
 let thumbnailKey=null;
 globalThis.__zicSource={url:'https://source.invalid/',comic:{
   loadInfo:async()=>({title:'Preview crop',chapters:{one:'One'},thumbnails:['/source.jpg@x=0-10&y=0-10','/source.jpg@x=10-20&y=0-10']}),
   onThumbnailLoad:async key=>{thumbnailKey=key;return {url:'https://cdn.invalid/source.jpg'}}
 }};
 const detail=await __zicOperation({operation:'loadComic',arguments:{comicId}});
 const uri=detail.preview.items[1].uri;
 const request=await __zicOperation({operation:'resolveResource',arguments:{uri}});
 if(uri!=='https://source.invalid/source.jpg@x=10-20&y=0-10'||thumbnailKey!=='https://source.invalid/source.jpg'||request.url!=='https://cdn.invalid/source.jpg')throw new Error('preview crop identity was lost '+JSON.stringify({uri,thumbnailKey,request}));
}

async function checkChapterResourceCanBeReadAgain(){
 const comicId='venera:comic:'+__zicB64({id:'retry-comic',title:'Retry'});
 const chapter=__zicChapterMessage(comicId,'ep-retry','Retry episode',0);
 let requests=0,configs=0;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method!=='http_image_binary')throw new Error('unexpected resource bridge method '+message.method);
   requests++;
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{},nativeBytesToken:'resource-token-'+requests})});
 };
 globalThis.__zicSource={comic:{
  loadEp:async()=>({images:['retry-image']}),
  onImageLoad:async image=>{configs++;return {url:'https://cdn.invalid/'+image+'.jpg'}}
 }};
 const loaded=await __zicOperation({operation:'loadChapter',arguments:{chapterId:chapter.chapterId}});
 const uri=loaded.pages[0].uri;
 if(!uri.startsWith('venera-resource:')||uri.startsWith('venera-resource://'))throw new Error('chapter resource locator is not durable '+uri);
 await __zicOperation({operation:'loadResource',arguments:{uri}});
 await __zicOperation({operation:'loadResource',arguments:{uri}});
 if(configs!==1||requests!==2)throw new Error('resource config was not reused within one runtime '+JSON.stringify({configs,requests}));
 __zicResources.clear();
 __zicResourceConfigs.clear();
 __zicResourceResolutions.clear();
 await __zicOperation({operation:'loadResource',arguments:{uri}});
 if(configs!==2||requests!==3)throw new Error('chapter resource locator did not survive runtime state loss '+JSON.stringify({configs,requests}));
}


async function checkLegacyChapterResourceToken(){
 let requests=0;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method!=='http_image_binary')throw new Error('unexpected legacy token bridge method '+message.method);
   requests++;
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{},nativeBytesToken:'legacy-token'})});
 };
 globalThis.__zicSource={comic:{}};
 const token=__zicRetainResource({url:'https://cdn.invalid/legacy.jpg',method:'GET',headers:{}});
 await __zicOperation({operation:'loadResource',arguments:{uri:'venera-resource://'+token}});
 if(requests!==1)throw new Error('legacy resource token compatibility failed');
}


async function checkStreamableOnLoadFailedConfig(){
 const locator='venera-resource:'+__zicB64({v:1,image:'streamable',comicId:'comic',epId:'ep'});
 let failedCalls=0,nativeCalls=0;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method==='cookie'&&message.function==='get')return JSON.stringify({ok:true,value:__zicEncode([])});
   if(message.method==='http'||message.method==='http_binary'||message.method==='http_image_binary')nativeCalls++;
   throw new Error('request-plan operation unexpectedly invoked native '+message.method);
 };
 globalThis.__zicSource={comic:{
   onImageLoad:async()=>({
     url:'https://cdn.invalid/original.webp',
     headers:{Referer:'https://gallery.invalid/'},
     onLoadFailed:async()=>{
       failedCalls++;
       return {url:'https://cdn.invalid/retry.webp',headers:{Referer:'https://gallery.invalid/'}};
     },
   }),
 }};
 const resolved=await __zicOperation({operation:'resolveResource',arguments:{uri:locator}});
 if(resolved.url!=='https://cdn.invalid/original.webp'||resolved.requiresRuntimeTransform!==false)throw new Error('streamable onLoadFailed request was forced through runtime bytes '+JSON.stringify(resolved));
 if(resolved.headers['Accept-Encoding']!=='identity')throw new Error('streamable request lost identity encoding '+JSON.stringify(resolved));
 if(failedCalls!==0||nativeCalls!==0)throw new Error('resolveResource executed the retry/body path '+JSON.stringify({failedCalls,nativeCalls}));
 const retry=await __zicOperation({operation:'retryResource',arguments:{uri:locator}});
 if(!retry.available||retry.request.url!=='https://cdn.invalid/retry.webp'||retry.request.requiresRuntimeTransform!==false)throw new Error('retryResource did not return a replacement request plan '+JSON.stringify(retry));
 if(failedCalls!==1||nativeCalls!==0)throw new Error('retryResource invoked the wrong path '+JSON.stringify({failedCalls,nativeCalls}));
}

async function checkFreshResourceGenerationRestartsInitialConfig(){
 const locator='venera-resource:'+__zicB64({v:1,image:'fresh-resource',comicId:'comic',epId:'ep'});
 let configCalls=0,failedCalls=0;
 globalThis.__zicSource={comic:{
   onImageLoad:async()=>{
     configCalls++;
     return {
       url:'https://cdn.invalid/initial-'+configCalls+'.webp',
       onLoadFailed:async()=>{
         failedCalls++;
         return {url:'https://cdn.invalid/replacement-'+failedCalls+'.webp'};
       },
     };
   },
 }};
 const first=await __zicOperation({operation:'resolveResource',arguments:{uri:locator}});
 const retry=await __zicOperation({operation:'retryResource',arguments:{uri:locator}});
 if(first.url!=='https://cdn.invalid/initial-1.webp'||retry.request.url!=='https://cdn.invalid/replacement-1.webp'||configCalls!==1||failedCalls!==1)throw new Error('fresh generation fixture setup failed '+JSON.stringify({first,retry,configCalls,failedCalls}));
 const retained=await __zicOperation({operation:'resolveResource',arguments:{uri:locator}});
 if(retained.url!=='https://cdn.invalid/replacement-1.webp'||configCalls!==1)throw new Error('ordinary resolve escaped the retained semantic chain '+JSON.stringify({retained,configCalls}));
 const fresh=await __zicOperation({operation:'resolveResource',arguments:{uri:locator,fresh:true}});
 if(fresh.url!=='https://cdn.invalid/initial-2.webp'||configCalls!==2||failedCalls!==1)throw new Error('fresh resource generation did not rebuild initial source config '+JSON.stringify({fresh,configCalls,failedCalls}));
}

async function checkFreshResourceGenerationBypassesResolverCache(){
 const locator='venera-resource:'+__zicB64({v:1,image:'fresh-resolver-cache',comicId:'comic',epId:'ep'});
 const seen=[];let configCalls=0;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method==='cookie'&&message.function==='get')return JSON.stringify({ok:true,value:__zicEncode([])});
   if(message.method!=='http')throw new Error('unexpected fresh-resolver bridge method '+message.method);
   seen.push(message.__zicFreshResolver===true);
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{},body:'resolver'})});
 };
 globalThis.__zicSource={comic:{onImageLoad:async()=>{configCalls++;await Network.get('https://resolver.invalid/page');return {url:'https://cdn.invalid/page-'+configCalls+'.webp'}}}};
 const ordinary=await __zicOperation({operation:'resolveResource',arguments:{uri:locator}});
 if(ordinary.url!=='https://cdn.invalid/page-1.webp'||JSON.stringify(seen)!==JSON.stringify([false]))throw new Error('ordinary resource resolve unexpectedly bypassed resolver cache '+JSON.stringify({ordinary,seen}));
 const fresh=await __zicOperation({operation:'resolveResource',arguments:{uri:locator,fresh:true}});
 if(fresh.url!=='https://cdn.invalid/page-2.webp'||JSON.stringify(seen)!==JSON.stringify([false,true])||configCalls!==2)throw new Error('fresh resource resolve did not bypass resolver cache '+JSON.stringify({fresh,seen,configCalls}));
 const retained=await __zicOperation({operation:'resolveResource',arguments:{uri:locator}});
 if(retained.url!==fresh.url||seen.length!==2||configCalls!==2)throw new Error('ordinary retained resolve repeated fresh resolver work '+JSON.stringify({retained,seen,configCalls}));
}

async function checkNonImageBodyUsesSourceRecovery(){
 const locator='venera-resource:'+__zicB64({v:1,image:'semantic-retry',comicId:'comic',epId:'ep'});
 let failedCalls=0,requests=0;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method==='cookie'&&message.function==='get')return JSON.stringify({ok:true,value:__zicEncode([])});
   if(message.method!=='http_image_binary')throw new Error('unexpected semantic-retry bridge method '+message.method);
   requests++;
   if(requests===1){
     if(message.url!=='https://cdn.invalid/bad')throw new Error('first semantic-retry URL mismatch '+message.url);
     return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{'content-type':'text/html'},encodedImage:false,bodyLength:27})});
   }
   if(message.url!=='https://cdn.invalid/good.webp')throw new Error('replacement semantic-retry URL mismatch '+message.url);
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{'content-type':'image/webp'},encodedImage:true,bodyLength:128,nativeBytesToken:'semantic-retry-token'})});
 };
 globalThis.__zicSource={comic:{
   onImageLoad:async()=>({
     url:'https://cdn.invalid/bad',
     onLoadFailed:async()=>{
       failedCalls++;
       return {url:'https://cdn.invalid/good.webp'};
     },
   }),
 }};
 const loaded=await __zicOperation({operation:'loadResource',arguments:{uri:locator}});
 if(loaded?.__zicNativeBytesToken!=='semantic-retry-token'||failedCalls!==1||requests!==2)throw new Error('200 non-image body did not use exactly one source semantic recovery '+JSON.stringify({loaded,failedCalls,requests}));
}

async function checkExternalSemanticRetryContinuesCurrentReplacementChain(){
 const locator='venera-resource:'+__zicB64({v:1,image:'external-semantic-retry',comicId:'comic',epId:'ep'});
 let configCalls=0,failedCalls=0,replacementFailedCalls=0,requests=0;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method==='cookie'&&message.function==='get')return JSON.stringify({ok:true,value:__zicEncode([])});
   if(message.method!=='http_image_binary')throw new Error('unexpected external semantic-retry bridge method '+message.method);
   requests++;
   if(requests===1){
     if(message.url!=='https://cdn.invalid/replacement.webp')throw new Error('runtime fallback replayed the wrong semantic URL '+message.url);
     return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{'content-type':'text/html'},encodedImage:false,bodyLength:31})});
   }
   if(message.url!=='https://cdn.invalid/second-replacement.webp')throw new Error('runtime fallback did not advance the current replacement chain '+message.url);
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{'content-type':'image/webp'},encodedImage:true,bodyLength:128,nativeBytesToken:'second-replacement-token'})});
 };
 globalThis.__zicSource={comic:{
   onImageLoad:async()=>{
     configCalls++;
     return {
       url:'https://cdn.invalid/original.webp',
       onLoadFailed:async()=>{
         failedCalls++;
         return {
           url:'https://cdn.invalid/replacement.webp',
           onLoadFailed:async()=>{
             replacementFailedCalls++;
             return {url:'https://cdn.invalid/second-replacement.webp'};
           },
         };
       },
     };
   },
 }};
 const resolved=await __zicOperation({operation:'resolveResource',arguments:{uri:locator}});
 if(resolved.url!=='https://cdn.invalid/original.webp')throw new Error('external semantic retry initial plan mismatch '+JSON.stringify(resolved));
 const retry=await __zicOperation({operation:'retryResource',arguments:{uri:locator}});
 if(!retry.available||retry.request.url!=='https://cdn.invalid/replacement.webp'||failedCalls!==1)throw new Error('external semantic retry did not produce first replacement '+JSON.stringify({retry,failedCalls}));
 const loaded=await __zicOperation({operation:'loadResource',arguments:{uri:locator}});
 if(loaded?.__zicNativeBytesToken!=='second-replacement-token'||requests!==2||replacementFailedCalls!==1)throw new Error('runtime fallback did not continue current replacement recovery '+JSON.stringify({loaded,requests,replacementFailedCalls}));
 if(configCalls!==1||failedCalls!==1)throw new Error('semantic chain incorrectly reran original onImageLoad/onLoadFailed '+JSON.stringify({configCalls,failedCalls}));
 const exhausted=await __zicOperation({operation:'retryResource',arguments:{uri:locator}});
 if(exhausted.available!==false||configCalls!==1)throw new Error('completed replacement chain unexpectedly restarted original image config '+JSON.stringify({exhausted,configCalls}));
}

async function checkChapterImageConfigIsDeferred(){
 const comicId='venera:comic:'+__zicB64({id:'deferred-comic',title:'Deferred'});
 const chapter=__zicChapterMessage(comicId,'ep-deferred','Deferred episode',0);
 let configs=0,requests=0;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method!=='http_image_binary')throw new Error('unexpected deferred bridge method '+message.method);
   requests++;
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{},nativeBytesToken:'deferred-token'})});
 };
 globalThis.__zicSource={comic:{
   loadEp:async()=>({images:['image-1','image-2']}),
   onImageLoad:async(image,seenComicId,epId)=>{
     configs++;
     if(seenComicId!=='deferred-comic'||epId!=='ep-deferred')throw new Error('deferred image identity lost');
     return {url:'https://cdn.invalid/'+image+'.jpg'};
   }
 }};
 const loaded=await __zicOperation({operation:'loadChapter',arguments:{chapterId:chapter.chapterId}});
 if(configs!==0||requests!==0||loaded.pages.length!==2)throw new Error('chapter eagerly resolved image config');
 await __zicOperation({operation:'loadResource',arguments:{uri:loaded.pages[1].uri}});
 if(configs!==1||requests!==1)throw new Error('resource did not lazily resolve one image config');
}


async function checkRequestPlanReuseAndThumbnailPath(){
 const locator='venera-resource:'+__zicB64({v:1,image:'page-1',comicId:'comic',epId:'ep'});
 let pageConfigs=0,thumbnailConfigs=0;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method==='cookie'&&message.function==='get')return JSON.stringify({ok:true,value:__zicEncode([])});
   throw new Error('request-plan reuse unexpectedly invoked native '+message.method);
 };
 globalThis.__zicSource={comic:{
   onImageLoad:async()=>{pageConfigs++;return {url:'https://cdn.invalid/page.webp'}},
   onThumbnailLoad:async uri=>{thumbnailConfigs++;return {url:String(uri).replace('cover','thumb')}},
 }};
 const first=await __zicOperation({operation:'resolveResource',arguments:{uri:locator}});
 const second=await __zicOperation({operation:'resolveResource',arguments:{uri:locator}});
 if(first.url!==second.url||pageConfigs!==1)throw new Error('durable request plan was re-resolved '+JSON.stringify({first,second,pageConfigs}));
 const cover='https://cdn.invalid/cover.webp';
 const coverFirst=await __zicOperation({operation:'resolveResource',arguments:{uri:cover}});
 const coverSecond=await __zicOperation({operation:'resolveResource',arguments:{uri:cover}});
 if(coverFirst.url!=='https://cdn.invalid/thumb.webp'||coverSecond.url!==coverFirst.url||thumbnailConfigs!==1||pageConfigs!==1)throw new Error('thumbnail request plan was not cached '+JSON.stringify({coverFirst,coverSecond,thumbnailConfigs,pageConfigs}));
}

async function checkSourceSettings(){
 const stored=new Map(),actions=[];
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method==='load_setting')return JSON.stringify({ok:true,value:__zicEncode(stored.has(message.setting_key)?stored.get(message.setting_key):null)});
   if(message.method==='save_setting'){stored.set(message.setting_key,message.value);return JSON.stringify({ok:true,value:null})}
   if(message.method==='getLocale')return JSON.stringify({ok:true,value:'zh_CN'});
   throw new Error('unexpected settings bridge method '+message.method);
 };
 class SettingsSource extends ComicSource {
   key='settings';name='Settings';translation={zh_CN:{Enabled:'已启用',Mirror:'镜像',Auto:'自动',Refresh:'刷新',Run:'执行'}};
   settings={
     enabled:{title:'Enabled',type:'switch',default:false},
     mirror:{title:'Mirror',type:'select',options:[{value:'auto',text:'Auto'},{value:'two'}],default:'auto'},
     refresh:{title:'Refresh',type:'callback',buttonText:'Run',callback:()=>UI.showDialog('Confirm','Apply?', [{text:'Cancel',callback:()=>actions.push('cancel')},{text:'Apply',callback:()=>actions.push('refresh')}])},
   };
 }
 globalThis.__zicSource=new SettingsSource();
 let values=await __zicOperation({operation:'loadSourceSettings',arguments:{}});
 if(values.length!==3||values[0].kind!=='toggle'||values[0].value!==false)throw new Error('toggle setting failed '+JSON.stringify(values));
 if(values[1].kind!=='select'||values[1].value!=='auto'||values[1].choices[0].label!=='自动')throw new Error('select setting failed '+JSON.stringify(values[1]));
 if(values[2].kind!=='action'||values[2].value!=='执行')throw new Error('action setting failed '+JSON.stringify(values[2]));
 await __zicOperation({operation:'updateSourceSetting',arguments:{key:'enabled',value:true}});
 await __zicOperation({operation:'updateSourceSetting',arguments:{key:'mirror',value:'two'}});
 await __zicOperation({operation:'updateSourceSetting',arguments:{key:'refresh',value:true}});
 values=await __zicOperation({operation:'loadSourceSettings',arguments:{}});
 if(values[0].value!==true||values[1].value!=='two'||actions.length!==1)throw new Error('settings update failed '+JSON.stringify({values,actions,stored:Array.from(stored)}));
}

async function checkSourceAccount(){
 const stored=new Map(),cookieWrites=[],calls=[];
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method==='load_data')return JSON.stringify({ok:true,value:__zicEncode(stored.has(message.data_key)?stored.get(message.data_key):null)});
   if(message.method==='save_data'){stored.set(message.data_key,message.data);return JSON.stringify({ok:true,value:null})}
   if(message.method==='delete_data'){stored.delete(message.data_key);return JSON.stringify({ok:true,value:null})}
   if(message.method==='isLogged')return JSON.stringify({ok:true,value:stored.has('account')});
   if(message.method==='cookie'&&message.function==='set'){cookieWrites.push({url:message.url,cookies:message.cookies});return JSON.stringify({ok:true,value:null})}
   throw new Error('unexpected account bridge method '+message.method);
 };
 class AccountSource extends ComicSource {
   key='account';name='Account';
   account={
     registerWebsite:'https://account.invalid/register',
     login:async(account,password)=>{calls.push(['credentials',account,password]);return true},
     loginWithCookies:{fields:['igneous','ipb_member_id'],validate:async values=>{calls.push(['cookies',...values]);return values[0]==='igneous-value'&&values[1]==='member-value'}},
     loginWithWebview:{url:'https://account.invalid/login',checkStatus:(url,title)=>{calls.push(['web',url,title]);return url.endsWith('/done')&&title==='Done'},onLoginSuccess:()=>calls.push(['web-success'])},
     logout:()=>calls.push(['logout']),
   };
 }
 globalThis.__zicSource=new AccountSource();
 __zicInstallSourceData(globalThis.__zicSource);
 let descriptor=await __zicOperation({operation:'loadSourceAccount',arguments:{}});
 if(descriptor.loggedIn||!descriptor.supportsCredentials||descriptor.cookieFields.join(',')!=='igneous,ipb_member_id'||descriptor.loginWebsite!=='https://account.invalid/login'||descriptor.registerWebsite!=='https://account.invalid/register')throw new Error('account descriptor failed '+JSON.stringify(descriptor));
 await __zicOperation({operation:'loginSourceAccount',arguments:{mode:'credentials',values:{account:'user',password:'pass'}}});
 if(!stored.has('account')||calls[0].join(',')!=='credentials,user,pass')throw new Error('credential login failed '+JSON.stringify({stored:Array.from(stored),calls}));
 await __zicOperation({operation:'logoutSourceAccount',arguments:{}});
 await __zicOperation({operation:'loginSourceAccount',arguments:{mode:'cookies',values:{cookies:{ipb_member_id:'member-value',igneous:'igneous-value'}}}});
 if(calls.find(entry=>entry[0]==='cookies').join(',')!=='cookies,igneous-value,member-value')throw new Error('cookie order failed '+JSON.stringify(calls));
 await __zicOperation({operation:'logoutSourceAccount',arguments:{}});
 await __zicOperation({operation:'loginSourceAccount',arguments:{mode:'web',values:{currentUrl:'https://account.invalid/done',title:'Done',cookies:{sid:'cookie-value'},localStorage:{token:'storage-value'}}}});
 if(cookieWrites.length!==1||cookieWrites[0].cookies.sid!=='cookie-value'||stored.get('_localStorage')?.token!=='storage-value'||!calls.some(entry=>entry[0]==='web-success'))throw new Error('web login failed '+JSON.stringify({cookieWrites,calls}));
 descriptor=await __zicOperation({operation:'loadSourceAccount',arguments:{}});
 if(!descriptor.loggedIn)throw new Error('logged-in state was not persisted');
 await __zicOperation({operation:'logoutSourceAccount',arguments:{}});
 if(stored.has('account'))throw new Error('logout did not clear account');
}

async function checkNetworkExtraAndCryptoSurface(){
 let seen=null;
 ZicNative.request=raw=>{seen=__zicDecode(JSON.parse(raw));return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{},body:'ok'})})};
 await Network.get('https://api.invalid/data',{'x-test':'1'},{interceptor:'value'});
 if(seen.data!==undefined||seen.extra?.interceptor!=='value')throw new Error('Network.get extra mapping failed '+JSON.stringify(seen));
 if(typeof Convert.encryptAesEcb!=='function'||Convert.encryptAesCfb.length!==4||Convert.decryptAesCfb.length!==4)throw new Error('Convert AES surface is incomplete');
}

async function checkRequestPlanStageDiagnostics(){
 const requestId='plan-stage-diagnostics';
 const locator='venera-resource:'+__zicB64({v:1,image:'stage-image',comicId:'comic',epId:'ep'});
 let completed=null,finished=null;
 globalThis.__zicSource={comic:{
   onImageLoad:async image=>{
     await Network.get('https://resolver.invalid/key');
     return {url:'https://cdn.invalid/'+image+'.webp'};
   },
 }};
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method==='cookie'&&message.function==='get')return JSON.stringify({ok:true,value:__zicEncode([])});
   if(message.method!=='http'||message.requestId!==requestId)throw new Error('plan stage diagnostics lost request-scoped bridge network '+JSON.stringify(message));
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{},body:'resolver'})});
 };
 ZicNative.complete=(seenRequestId,envelope)=>{completed={seenRequestId,envelope:JSON.parse(envelope)}};
 ZicNative.finished=seenRequestId=>{finished=seenRequestId};
 await __zicInvoke({requestId,operation:'resolveResource',arguments:{uri:locator}});
 const resolved=completed&&__zicDecode(completed.envelope.value),diagnostics=resolved?.__zicDiagnostics;
 if(completed?.seenRequestId!==requestId||finished!==requestId||resolved?.url!=='https://cdn.invalid/stage-image.webp'||!diagnostics||diagnostics.sourcePlanBridgeNetworkCalls!==1||diagnostics.sourcePlanBridgeNetworkCacheHits!==0||diagnostics.sourcePlanBridgeNetworkOriginCalls!==1||diagnostics.sourcePlanBridgeNetworkMicros<0||diagnostics.sourcePlanHookMicros<diagnostics.sourcePlanBridgeNetworkMicros||__zicBridgeMetrics.has(requestId))throw new Error('request-plan stage diagnostics failed '+JSON.stringify({completed,finished,resolved,retained:__zicBridgeMetrics.has(requestId)}));
}

async function checkResolverNetworkFailureRetryability(){
 const requestId='resolver-network-failure';
 const locator='venera-resource:'+__zicB64({v:1,image:'tls-image',comicId:'comic',epId:'ep'});
 const previousRequestAsync=ZicNative.requestAsync;
 let completed=null,finished=null,seen=null;
 globalThis.__zicSource={comic:{
   onImageLoad:async image=>{
     await Network.get('https://resolver.invalid/key');
     return {url:'https://cdn.invalid/'+image+'.webp'};
   },
 }};
 ZicNative.requestAsync=raw=>{
   const message=__zicDecode(JSON.parse(raw));seen=message;
   setTimeout(()=>__zicBridgeResponse(message.bridgeCallId,JSON.stringify({
     ok:false,
     error:"venera-resolver-http-failed: [RhttpUnknownException] cannot decrypt peer's message",
     errorCode:'venera-resolver-http-failed',
     retryable:true,
   })),0);
 };
 ZicNative.complete=(seenRequestId,envelope)=>{completed={seenRequestId,envelope:JSON.parse(envelope)}};
 ZicNative.finished=seenRequestId=>{finished=seenRequestId};
 try{
   await __zicInvoke({requestId,operation:'resolveResource',arguments:{uri:locator}});
 }finally{
   if(previousRequestAsync===undefined)delete ZicNative.requestAsync;else ZicNative.requestAsync=previousRequestAsync;
 }
 const result=completed?.envelope;
 if(seen?.requestId!==requestId||completed?.seenRequestId!==requestId||finished!==requestId||result?.ok!==false||result?.code!=='venera-operation-failed'||result?.retryable!==true||!String(result?.message||'').includes("cannot decrypt peer's message"))throw new Error('resolver network failure lost retryability '+JSON.stringify({seen,completed,finished}));
}

async function checkRequestScopedDelayCancellation(){
 const requestId='delay-cancel';
 __zicActiveRequestId=requestId;
 const started=Date.now();
 const delayed=sendMessage({method:'delay',time:5000});
 __zicCancel(requestId);
 let cancelled=false;
 try{await delayed}catch(error){cancelled=String(error).includes('cancelled')}
 const elapsed=Date.now()-started;
 __zicCancelled.delete(requestId);
 __zicActiveRequestId=null;
 if(!cancelled||elapsed>500||__zicDelayWaiters.has(requestId))throw new Error('request-scoped delay did not cancel promptly '+JSON.stringify({cancelled,elapsed,retained:__zicDelayWaiters.has(requestId)}));
}

async function checkAsyncNetworkBridgeAndActivationGate(){
 let seen=null,completed=null,finished=null;
 const previousRequestAsync=ZicNative.requestAsync;
 ZicNative.requestAsync=raw=>{
   const message=__zicDecode(JSON.parse(raw));seen=message;
   setTimeout(()=>__zicBridgeResponse(message.bridgeCallId,JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{},body:'background'})})),30);
 };
 const background=Network.get('https://api.invalid/background');
 __zicActivationOpen=false;
 globalThis.__zicSource={};
 ZicNative.complete=(requestId,envelope)=>{completed={requestId,envelope:JSON.parse(envelope)}};
 ZicNative.finished=requestId=>{finished=requestId};
 const started=Date.now();
 await __zicInvoke({requestId:'activation-gate',operation:'loadBrowseSections',arguments:{}});
 const elapsed=Date.now()-started;
 if(seen?.requestId!==undefined||completed?.requestId!=='activation-gate'||finished!=='activation-gate'||elapsed<20||__zicActivationWork.size)throw new Error('async activation bridge did not gate the next invocation '+JSON.stringify({seen,completed,finished,elapsed,retained:__zicActivationWork.size}));
 await background;
 let cancelledComplete=null,cancelledFinished=null;
 ZicNative.complete=(requestId,envelope)=>{cancelledComplete={requestId,envelope}};
 ZicNative.finished=requestId=>{cancelledFinished=requestId};
 const cancelledInvocation=__zicInvoke({requestId:'async-cancel',operation:'loadResource',arguments:{uri:'https://api.invalid/cancel'}});
 setTimeout(()=>__zicCancel('async-cancel'),5);
 await cancelledInvocation;
 if(cancelledComplete!==null||cancelledFinished!=='async-cancel')throw new Error('async bridge cancellation released the invocation early '+JSON.stringify({cancelledComplete,cancelledFinished}));
 if(previousRequestAsync===undefined)delete ZicNative.requestAsync;else ZicNative.requestAsync=previousRequestAsync;
}

async function checkInvokeRequestLifecycle(){
 let seenRequestId=null,completed=null,finished=null;
 globalThis.__zicSource={comic:{onImageLoad:async()=>({url:'https://cdn.invalid/image.jpg',method:'GET',data:'must-not-cross-get'})}};
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));
   if(message.method!=='http_image_binary')throw new Error('unexpected invoke lifecycle method '+message.method);
   seenRequestId=message.requestId;
   if(message.data!==undefined)throw new Error('GET resource data crossed the bridge');
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{},nativeBytesToken:'invoke-token'})});
 };
 ZicNative.complete=(requestId,envelope)=>{completed={requestId,envelope:JSON.parse(envelope)}};
 ZicNative.finished=requestId=>{finished=requestId};
 await __zicInvoke({requestId:'invoke-lifecycle',operation:'loadResource',arguments:{uri:'https://cdn.invalid/image.jpg'}});
 if(seenRequestId!=='invoke-lifecycle'||completed?.requestId!=='invoke-lifecycle'||finished!=='invoke-lifecycle')throw new Error('invoke lifecycle did not retain the request id '+JSON.stringify({seenRequestId,completed,finished}));
}

(async()=>{await checkCurrentCategory();await checkStableEntityIds();await checkLegacyCategory();await checkExploreObject();await checkLoadNextExplore();await checkSearchOptionDefaults();await checkLegacyGlobalScratchBinding();await checkDirectCoverResource();await checkChapterPageCount();await checkWebpPageHints();await checkSingleVolumeChapter();await checkComicPreviewPagination();await checkPreviewCropIdentity();await checkChapterResourceCanBeReadAgain();await checkLegacyChapterResourceToken();await checkStreamableOnLoadFailedConfig();await checkFreshResourceGenerationRestartsInitialConfig();await checkFreshResourceGenerationBypassesResolverCache();await checkNonImageBodyUsesSourceRecovery();await checkExternalSemanticRetryContinuesCurrentReplacementChain();await checkChapterImageConfigIsDeferred();await checkRequestPlanReuseAndThumbnailPath();await checkSourceSettings();await checkSourceAccount();await checkNetworkExtraAndCryptoSurface();await checkRequestPlanStageDiagnostics();await checkResolverNetworkFailureRetryability();await checkRequestScopedDelayCancellation();await checkAsyncNetworkBridgeAndActivationGate();await checkInvokeRequestLifecycle();console.log('Venera bootstrap contract: OK')})().catch(e=>{console.error(e);process.exit(1)});
'''
with tempfile.TemporaryDirectory() as td:
    js=Path(td)/'test.js'; js.write_text(bootstrap+'\n'+test)
    subprocess.run(['node',str(js)],check=True)
