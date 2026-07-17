void exit(int);
int getchar(void);
void *malloc(int);
int putchar(int);
int main1();
int main() { return main1(); }
int main1()
{
  int c;
  c = getchar();
  while (c != 0-1) {
    putchar(c);
    c = c + 0;
    c = getchar();
  }
  return 0;
}
