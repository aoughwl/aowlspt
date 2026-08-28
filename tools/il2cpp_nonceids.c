#include <windows.h>
#include <stdio.h>
#include <intrin.h>
typedef unsigned long long u64;
typedef u64 (*nonce_t)(unsigned apiId);
typedef void*(*deriv_t)(u64 nonce);
typedef u64 (*getoff_t)(void* field, void* tok);
#define TLS_INDEX_RVA 0x70B4958
static unsigned char* tlsblock(unsigned char* base){
  unsigned idx=*(unsigned*)(base+TLS_INDEX_RVA);
  unsigned char** arr=(unsigned char**)__readgsqword(0x58);
  return arr[idx];
}
int main(void){
  setvbuf(stdout,NULL,_IONBF,0);
  SetDllDirectoryA("D:/Games/Tarkov");
  HMODULE h=LoadLibraryExA("D:/Games/Tarkov/GameAssembly.dll",NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
  if(!h){printf("LOADFAIL %lu\n",GetLastError());return 1;}
  unsigned char* base=(unsigned char*)h;
  nonce_t nonce=(nonce_t)GetProcAddress(h,"il2cpp_nonce");
  printf("il2cpp_nonce=%p  tls_index=%u\n",(void*)nonce,*(unsigned*)(base+TLS_INDEX_RVA));
  unsigned char* blk=tlsblock(base);
  printf("tls block=%p\n",(void*)blk);
  /* slots our scan found, in the generated map */
  unsigned slots[]={0x118,0x140,0x148,0x170,0x198,0x200,0x208,0x270,0x278,0x280,0x288,0x2B0,0x2D8,0x2E0};
  int ns=sizeof(slots)/sizeof(slots[0]);
  printf("\napiId -> slot(s) that became non-zero\n");
  for(unsigned id=0x00;id<=0xA0;id++){
    for(int i=0;i<ns;i++) *(u64*)(blk+slots[i])=0;
    u64 r=nonce(id);
    for(int i=0;i<ns;i++){
      u64 v=*(u64*)(blk+slots[i]);
      if(v) printf("  id=0x%02X slot=0x%03X nonce=%016llX ret=%016llX %s\n",
                   id,slots[i],v,r,(v==r)?"(ret==slot)":"");
    }
  }
  return 0;
}
