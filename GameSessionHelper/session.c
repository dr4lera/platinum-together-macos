#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
static BYTE entropy[]="PlatinumTogether online sign-in 1";
static int seal(BYTE *data,DWORD size,DATA_BLOB *out){ DATA_BLOB in={size,data},e={sizeof(entropy)-1,entropy};return CryptProtectData(&in,L"Platinum Together sign-in",&e,0,0,CRYPTPROTECT_UI_FORBIDDEN,out); }
static int unseal(DATA_BLOB *in,DATA_BLOB *out){DATA_BLOB e={sizeof(entropy)-1,entropy};return CryptUnprotectData(in,0,&e,0,0,CRYPTPROTECT_UI_FORBIDDEN,out);}
static void clear(DATA_BLOB *b){if(b->pbData){SecureZeroMemory(b->pbData,b->cbData);LocalFree(b->pbData);}}
int main(int argc,char **argv){
 if(argc==2&&!strcmp(argv[1],"--running")){
  int running=0;HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);PROCESSENTRY32W entry={0};entry.dwSize=sizeof(entry);
  if(snapshot==INVALID_HANDLE_VALUE){puts("{\"ok\":false}");return 1;}
  if(Process32FirstW(snapshot,&entry))do{if(!_wcsicmp(entry.szExeFile,L"Platinum.exe"))running=1;}while(Process32NextW(snapshot,&entry));CloseHandle(snapshot);
  puts(running?"{\"ok\":true,\"running\":true}":"{\"ok\":true,\"running\":false}");return 0;
 }
 BYTE input[16384]={0};DWORD total=0,n=0;DATA_BLOB encrypted={0},plain={0};int ok=0;
 if(argc==2&&!strcmp(argv[1],"--selftest")){BYTE sample[]="local roundtrip test";ok=seal(sample,sizeof(sample),&encrypted)&&unseal(&encrypted,&plain)&&plain.cbData==sizeof(sample)&&!memcmp(sample,plain.pbData,sizeof(sample));goto finish;}
 if(argc!=2||strcmp(argv[1],"--import"))goto finish;
 while(ReadFile(GetStdHandle(STD_INPUT_HANDLE),input+total,sizeof(input)-total,&n,0)&&n){total+=n;if(total==sizeof(input))goto finish;}
 if(!total||input[0]!='{'||!strstr((char*)input,"\"schema\":1")||!strstr((char*)input,"https://pt-relay.kaicrits.com"))goto finish;
 if(!seal(input,total,&encrypted)||!unseal(&encrypted,&plain)||plain.cbData!=total||memcmp(input,plain.pbData,total))goto finish;
 WCHAR home[MAX_PATH],path[MAX_PATH],temp[MAX_PATH],lockpath[MAX_PATH];
 if(FAILED(SHGetFolderPathW(0,CSIDL_LOCAL_APPDATA,0,SHGFP_TYPE_CURRENT,home)))goto finish;
 wcscat(home,L"\\PlatinumTogether");CreateDirectoryW(home,0);
 swprintf(path,MAX_PATH,L"%ls\\online-sign-in.dat",home);swprintf(temp,MAX_PATH,L"%ls.tmp",path);swprintf(lockpath,MAX_PATH,L"%ls.lock",path);
 HANDLE lock=CreateFileW(lockpath,GENERIC_READ|GENERIC_WRITE,0,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);if(lock==INVALID_HANDLE_VALUE)goto finish;
 // Preserve existing game accounts; linking is for a missing game credential only.
 if(GetFileAttributesW(path)!=INVALID_FILE_ATTRIBUTES){CloseHandle(lock);goto finish;}
 HANDLE file=CreateFileW(temp,GENERIC_WRITE,0,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 if(file!=INVALID_HANDLE_VALUE){DWORD written=0;ok=WriteFile(file,encrypted.pbData,encrypted.cbData,&written,0)&&written==encrypted.cbData&&FlushFileBuffers(file);CloseHandle(file);if(ok)ok=MoveFileExW(temp,path,MOVEFILE_WRITE_THROUGH);if(!ok)DeleteFileW(temp);}
 CloseHandle(lock);
finish:
 SecureZeroMemory(input,sizeof(input));clear(&plain);clear(&encrypted);puts(ok?"{\"ok\":true}":"{\"ok\":false,\"message\":\"Game account handoff failed or a game account already exists.\"}");return ok?0:1;
}
