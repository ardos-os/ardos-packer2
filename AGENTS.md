### Requisitos do `ardos-packer2`

O `ardos-packer2` é um **gerador declarativo e reproduzível de ROMs do Ardos OS**, construído sobre o sistema de derivations do Nix, aproveitando o seu motor de builds, isolamento, cache e paralelismo, mas **sem depender do modelo de runtime do Nix**.

É uma reescrita do projeto original [ardos-packer](https.//github.com/ardos-os/ardos-packer), originalmente feito em Rust.

Os requisitos principais são:

* Usar **apenas derivations do Nix** como unidade de build.
* Aproveitar o **sandbox**, **grafo de dependências**, **cache local/remota** e **builds incrementais** do Nix.
* Gerar uma **ROM (`.squashfs`) com a estrutura de filesystem do ardos os (versão modificada do FHS)**, sem `/nix/store`.
* Tratar o **Ardos como uma plataforma/target própria** (ex.: `x86_64-*-ardos-*`), separada do Linux GNU convencional.
* Construir um **`stdenv`** que reutiliza a infraestrutura do `stdenv` do Nix, mas adapta o processo de compilação ao runtime do Ardos.
* Durante o **build**, os compiladores só podem ver dependências declaradas na `/nix/store`, garantindo isolamento total.
* Em **runtime**, os binários devem procurar bibliotecas apenas nos caminhos finais do Ardos, sem depender da `/nix/store` nem de `patchelf`.
* Cada derivation deve declarar o seu **layout de instalação em runtime** (onde os seus ficheiros existirão na ROM), sendo essa a única fonte de verdade. Os consumidores nunca assumem caminhos como `/usr/lib` ou `/ardos/lib`.
* O linker deve obter automaticamente os caminhos de runtime a partir das dependências declaradas, evitando configurações globais e problemas de "split brain".
* O gerador da ROM deve calcular automaticamente o **closure transitivo** das dependências e incluir todos os ficheiros necessários, sem que o utilizador tenha de listar manualmente dependências indiretas.
* O kernel, bootloader, imagem de disco, ROM e scripts de arranque da VM devem ser **artefactos independentes**, cada um representado por derivations próprias.
* O sistema deve permitir **cross-compilation** para outras arquiteturas (como ARM64) apenas alterando a plataforma alvo, reutilizando a mesma infraestrutura.
* O objetivo é proporcionar uma **excelente experiência de desenvolvimento**, em que um programador que altere apenas um componente do Ardos recompila apenas esse componente e os artefactos que dele dependem, enquanto todo o restante é obtido da cache do Nix.



## O teu modo de trabalho

Seu modo de trabalho é ser minimalista e evitar trabalho desnecessário. Não reinvente a roda. Analise o contexto existente no Nixpkgs e no nosso código, identifique as abstrações já presentes e proponha sempre a menor alteração arquitetônica possível. Itere sobre as suas alterações até que você consiga encontrar
a maneira canónica de se fazer algo.

Além disso, otimiza sempre o código para tempo de build e cache hits. Evita desencadear rebuilds colossais desnecessários em casos onde os patches aplicados não geram resultados diferentes na saída.