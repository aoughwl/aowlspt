#include <windows.h>
#include <stdio.h>
typedef unsigned long long u64;
typedef u64  (*nonce_t)(unsigned);
typedef void*(*deriv_t)(u64);
typedef u64  (*getoff_t)(void*,void*);
#define DERIV_FIELD_GET_OFFSET 0x5B93B0
#define APIID_FIELD_GET_OFFSET 0x58
int main(void){
  setvbuf(stdout,NULL,_IONBF,0);
  SetDllDirectoryA("D:/Games/Tarkov");
  HMODULE h=LoadLibraryExA("D:/Games/Tarkov/GameAssembly.dll",NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
  if(!h){printf("LOADFAIL\n");return 1;}
  unsigned char*base=(unsigned char*)h;
  nonce_t  nonce=(nonce_t)GetProcAddress(h,"il2cpp_nonce");
  getoff_t f=(getoff_t)GetProcAddress(h,"il2cpp_field_get_offset");
  deriv_t  deriv=(deriv_t)(base+DERIV_FIELD_GET_OFFSET);
  /* staged FieldInfo we own; stock layout puts `offset` at +0x18 */
  unsigned char*fi=(unsigned char*)VirtualAlloc(0,0x1000,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
  memset(fi,0,0x1000);
  *(int*)(fi+0x18)=42;

  printf("--- NONCE handshake, correct derivation (expect stable 42) ---\n");
  for(int i=0;i<5;i++){
    u64 n=nonce(APIID_FIELD_GET_OFFSET);
    void*tok=deriv(n);
    u64 r=f(fi,tok);
    printf("  nonce=%016llX tok=%p -> %llu\n",n,tok,r);
  }
  printf("\n--- token from a WRONG nonce (expect varying random) ---\n");
  for(int i=0;i<5;i++){
    u64 n=nonce(APIID_FIELD_GET_OFFSET);
    void*tok=deriv(n^0xDEADBEEF);
    u64 r=f(fi,tok);
    printf("  -> %llu (0x%llX)\n",r,r);
  }
  printf("\n--- NO nonce obtained at all (slot empty) ---\n");
  for(int i=0;i<3;i++){
    unsigned char junk[32]; memset(junk,0xAB,32);
    u64 r=f(fi,junk);
    printf("  -> %llu (0x%llX)\n",r,r);
  }
  return 0;
}
