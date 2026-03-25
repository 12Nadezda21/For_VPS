" Cross-platform Vim config for macOS, Debian 12+, Ubuntu 22.04+
" Safe for first-run with vim-plug + unattended PlugInstall --sync

"*****************************************************************************
"" Vim-Plug core
"*****************************************************************************
let s:vimplug = expand('~/.vim/autoload/plug.vim')

if has('win32') && !has('win64')
  let s:curl = expand('C:\Windows\Sysnative\curl.exe')
else
  let s:curl = 'curl'
endif

if !filereadable(s:vimplug)
  if !executable(s:curl)
    echoerr "curl is required to bootstrap vim-plug"
    execute 'q!'
  endif

  silent execute '!' . s:curl . ' -fLo ' . shellescape(s:vimplug) .
        \ ' --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

call plug#begin(expand('~/.vim/plugged'))

"*****************************************************************************
"" Plugins
"*****************************************************************************
Plug 'preservim/nerdtree'
Plug 'jistr/vim-nerdtree-tabs'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-rhubarb'
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'airblade/vim-gitgutter'
Plug 'vim-scripts/grep.vim'
Plug 'Raimondi/delimitMate'
Plug 'preservim/tagbar'
Plug 'dense-analysis/ale'
Plug 'Yggdroot/indentLine'
Plug 'editor-bootstrap/vim-bootstrap-updater'
Plug 'joshdick/onedark.vim'

" FZF: prefer system install on macOS, otherwise install local copy
if isdirectory('/opt/homebrew/opt/fzf')
  Plug '/opt/homebrew/opt/fzf'
  Plug 'junegunn/fzf.vim'
elseif isdirectory('/usr/local/opt/fzf')
  Plug '/usr/local/opt/fzf'
  Plug 'junegunn/fzf.vim'
else
  Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --bin' }
  Plug 'junegunn/fzf.vim'
endif

" Session
Plug 'xolox/vim-misc'
Plug 'xolox/vim-session'

" C / C++
Plug 'vim-scripts/c.vim', { 'for': ['c', 'cpp'] }
Plug 'ludwig/split-manpage.vim'

" Python
Plug 'davidhalter/jedi-vim'
Plug 'raimon49/requirements.txt.vim', { 'for': 'requirements' }

" User extra bundles
if filereadable(expand('~/.vimrc.local.bundles'))
  source ~/.vimrc.local.bundles
endif

call plug#end()

filetype plugin indent on

" Fix hidden quotes in JSON
let g:vim_json_conceal = 0
let g:indentLine_setConceal = 0

syntax on

"*****************************************************************************
"" Basic setup
"*****************************************************************************
set encoding=utf-8
set fileencoding=utf-8
set fileencodings=utf-8
set ttyfast
set backspace=indent,eol,start

set tabstop=4
set softtabstop=0
set shiftwidth=4
set expandtab

let mapleader = ','

set hidden
set hlsearch
set incsearch
set ignorecase
set smartcase
set fileformats=unix,dos,mac
set autoread

if exists('$SHELL') && !empty($SHELL)
  let &shell = $SHELL
else
  set shell=/bin/sh
endif

" Session management
let g:session_directory = expand('~/.vim/session')
let g:session_autoload = 'no'
let g:session_autosave = 'no'
let g:session_command_aliases = 1

" Enable bracketed paste for Tmux / Screen
if &term =~# '^screen' || &term =~# '^tmux'
  let &t_BE = "\<Esc>[?2004h"
  let &t_BD = "\<Esc>[?2004l"
  let &t_PS = "\<Esc>[200~"
  let &t_PE = "\<Esc>[201~"
endif

"*****************************************************************************
"" Visual settings
"*****************************************************************************
set ruler
set number
set mouse=a
set mousemodel=popup
set wildmenu
set scrolloff=3
set laststatus=2
set showmode
set modeline
set modelines=10
set title
set titleold=Terminal
set titlestring=%F
set gcr=a:blinkon0
set noerrorbells visualbell t_vb=

if has('termguicolors')
  set termguicolors
else
  set t_Co=256
endif

" tmux/screen truecolor escape support
if &term =~# '^\(screen\|tmux\)'
  let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
endif

set background=dark
let no_buffers_menu = 1
let g:onedark_hide_endofbuffer = 0
if has('termguicolors')
  unlet! g:onedark_termcolors
else
  let g:onedark_termcolors = 256
endif
if !empty(globpath(&runtimepath, 'colors/onedark.vim'))
  silent! colorscheme onedark
else
  silent! colorscheme desert
endif

" IndentLine
let g:indentLine_enabled = 1
let g:indentLine_concealcursor = ''
let g:indentLine_char = '┆'
let g:indentLine_faster = 1

" Better statusline
set statusline=%F%m%r%h%w%=(%{&ff}/%Y)\ (line\ %l\/%L,\ col\ %c)\

if exists('*fugitive#statusline')
  set statusline+=%{fugitive#statusline()}
endif

" Search motions center screen
nnoremap n nzzzv
nnoremap N Nzzzv

" Paste toggle
nnoremap <F6> :set invpaste paste?<CR>
inoremap <F6> <C-o>:set invpaste paste?<CR>

if has('autocmd')
  autocmd GUIEnter * set visualbell t_vb=
endif

"*****************************************************************************
"" Airline
"*****************************************************************************
let g:airline_theme = 'powerlineish'
let g:airline#extensions#branch#enabled = 1
let g:airline#extensions#ale#enabled = 1
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tagbar#enabled = 1
let g:airline#extensions#virtualenv#enabled = 1
let g:airline_skip_empty_sections = 1
let g:airline_powerline_fonts = 1

if !exists('g:airline_symbols')
  let g:airline_symbols = {}
endif

let g:airline#extensions#tabline#left_sep = ''
let g:airline#extensions#tabline#left_alt_sep = ''
let g:airline_left_sep = ''
let g:airline_left_alt_sep = ''
let g:airline_right_sep = ''
let g:airline_right_alt_sep = ''
let g:airline_symbols.branch = ''
let g:airline_symbols.readonly = ''
let g:airline_symbols.linenr = ''

"*****************************************************************************
"" Abbreviations
"*****************************************************************************
cnoreabbrev W! w!
cnoreabbrev Q! q!
cnoreabbrev Qall! qall!
cnoreabbrev Wq wq
cnoreabbrev Wa wa
cnoreabbrev wQ wq
cnoreabbrev WQ wq
cnoreabbrev W w
cnoreabbrev Q q
cnoreabbrev Qall qall

"*****************************************************************************
"" NERDTree
"*****************************************************************************
let g:NERDTreeChDirMode = 2
let g:NERDTreeIgnore = ['node_modules', '\.rbc$', '\~$', '\.pyc$', '\.db$', '\.sqlite$', '__pycache__']
let g:NERDTreeSortOrder = ['^__\.py$', '\/$', '*', '\.swp$', '\.bak$', '\~$']
let g:NERDTreeShowBookmarks = 1
let g:nerdtree_tabs_focus_on_files = 1
let g:NERDTreeMapOpenInTabSilent = '<RightMouse>'
let g:NERDTreeWinSize = 40

set wildignore+=*/tmp/*,*.so,*.swp,*.zip,*.pyc,*.db,*.sqlite,*node_modules/

nnoremap <silent> <F2> :NERDTreeFind<CR>
nnoremap <silent> <F3> :NERDTreeToggle<CR>

"*****************************************************************************
"" Grep / terminal / commands
"*****************************************************************************
nnoremap <silent> <leader>f :Rgrep<CR>
let Grep_Default_Options = '-IR'
let Grep_Skip_Files = '*.log *.db'
let Grep_Skip_Dirs = '.git node_modules'

if exists(':terminal')
  nnoremap <silent> <leader>sh :terminal<CR>
endif

command! FixWhitespace :%s/\s\+$//e

"*****************************************************************************
"" Functions
"*****************************************************************************
if !exists('*s:setupWrapping')
  function! s:setupWrapping()
    set wrap
    set wm=2
    set textwidth=79
  endfunction
endif

"*****************************************************************************
"" Autocmd rules
"*****************************************************************************
augroup vimrc_sync_fromstart
  autocmd!
  autocmd BufEnter * syntax sync maxlines=200
augroup END

augroup vimrc_remember_cursor_position
  autocmd!
  autocmd BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | execute "normal! g`\"" | endif
augroup END

augroup vimrc_wrapping
  autocmd!
  autocmd BufRead,BufNewFile *.txt call s:setupWrapping()
augroup END

augroup vimrc_make_cmake
  autocmd!
  autocmd FileType make setlocal noexpandtab
  autocmd BufNewFile,BufRead CMakeLists.txt setlocal filetype=cmake
augroup END

augroup vimrc_python
  autocmd!
  autocmd FileType python setlocal expandtab shiftwidth=4 tabstop=8 colorcolumn=79 softtabstop=4
  autocmd FileType python setlocal formatoptions+=cq
  autocmd FileType python setlocal cinwords=if,elif,else,for,while,try,except,finally,def,class,with
augroup END

autocmd FileType c setlocal tabstop=4 shiftwidth=4 expandtab
autocmd FileType cpp setlocal tabstop=4 shiftwidth=4 expandtab

"*****************************************************************************
"" Mappings
"*****************************************************************************
inoremap jk <Esc>
noremap <Leader>h :<C-u>split<CR>
noremap <Leader>v :<C-u>vsplit<CR>

" Git
noremap <Leader>ga :Gwrite<CR>
noremap <Leader>gc :Git commit --verbose<CR>
noremap <Leader>gsh :Git push<CR>
noremap <Leader>gll :Git pull<CR>
noremap <Leader>gs :Git<CR>
noremap <Leader>gb :Git blame<CR>
noremap <Leader>gd :Gvdiffsplit<CR>
noremap <Leader>gr :GRemove<CR>

" Session
nnoremap <leader>so :OpenSession<Space>
nnoremap <leader>ss :SaveSession<Space>
nnoremap <leader>sd :DeleteSession<CR>
nnoremap <leader>sc :CloseSession<CR>

" Tabs
nnoremap <Tab> gt
nnoremap <S-Tab> gT
nnoremap <silent> <S-t> :tabnew<CR>

" Working dir / edit helpers
nnoremap <leader>. :lcd %:p:h<CR>
noremap <Leader>e :e <C-R>=expand('%:p:h') . '/'<CR>
noremap <Leader>te :tabe <C-R>=expand('%:p:h') . '/'<CR>

"*****************************************************************************
"" FZF / search
"*****************************************************************************
set wildmode=list:longest,list:full
set wildignore+=*.o,*.obj,.git,*.rbc,*.pyc,__pycache__

let $FZF_DEFAULT_COMMAND = "find . -path '*/\.*' -prune -o -path '*/node_modules/*' -prune -o -path '*/target/*' -prune -o -path '*/dist/*' -prune -o -type f -print -o -type l -print 2>/dev/null"

if executable('ag')
  let $FZF_DEFAULT_COMMAND = 'ag --hidden --ignore .git -g ""'
  set grepprg=ag\ --nogroup\ --nocolor
endif

if executable('rg')
  let $FZF_DEFAULT_COMMAND = 'rg --files --hidden --follow --glob "!.git/*"'
  set grepprg=rg\ --vimgrep
  command! -bang -nargs=* Find call fzf#vim#grep(
        \ 'rg --column --line-number --no-heading --fixed-strings --ignore-case --hidden --follow --glob "!.git/*" --color "always" ' .
        \ shellescape(<q-args>) . ' | tr -d "\017"',
        \ 1,
        \ <bang>0)
endif

cnoremap <C-P> <C-R>=expand('%:p:h') . '/'<CR>
nnoremap <silent> <leader>b :Buffers<CR>
nnoremap <silent> <leader>ff :FZF -m<CR>
nmap <leader>y :History:<CR>

" Close search highlight
nnoremap <silent> <leader><space> :noh<CR>

" Window movement
noremap <C-j> <C-w>j
noremap <C-k> <C-w>k
noremap <C-l> <C-w>l
noremap <C-h> <C-w>h

" Visual mode helpers
vmap < <gv
vmap > >gv
vnoremap J :m '>+1<CR>gv=gv
vnoremap K :m '<-2<CR>gv=gv

" Open current line on GitHub
nnoremap <Leader>o :.GBrowse<CR>

" Buffer nav
noremap <leader>z :bp<CR>
noremap <leader>q :bp<CR>
noremap <leader>x :bn<CR>
noremap <leader>w :bn<CR>
noremap <leader>c :bd<CR>

"*****************************************************************************
"" ALE / Tagbar / Python
"*****************************************************************************
let g:ale_linters = {}
call extend(g:ale_linters, {
      \ 'python': ['flake8'],
      \ })

nmap <silent> <F4> :TagbarToggle<CR>
let g:tagbar_autofocus = 1

let g:jedi#popup_on_dot = 0
let g:jedi#goto_assignments_command = '<leader>g'
let g:jedi#goto_definitions_command = '<leader>d'
let g:jedi#documentation_command = 'K'
let g:jedi#usages_command = '<leader>n'
let g:jedi#rename_command = '<leader>r'
let g:jedi#show_call_signatures = '0'
let g:jedi#completions_command = '<C-Space>'
let g:jedi#smart_auto_mappings = 0

let python_highlight_all = 1

"*****************************************************************************
"" Clipboard
"*****************************************************************************
if has('clipboard')
  if has('unnamedplus')
    set clipboard=unnamed,unnamedplus
  else
    set clipboard=unnamed
  endif
endif

nnoremap YY "+yy
vnoremap Y "+y
noremap <leader>p "+p
noremap <leader>P "+P

if has('macunix') && executable('pbcopy')
  vnoremap <C-c> :w !pbcopy<CR><CR>
endif

"*****************************************************************************
"" Platform-specific tweaks
"*****************************************************************************
if has('macunix')
  " macOS/Homebrew defaults are already covered above
else
  " Debian/Ubuntu: tagbar works best when universal-ctags is installed
endif

"*****************************************************************************
"" User local config
"*****************************************************************************
if filereadable(expand('~/.vimrc.local'))
  source ~/.vimrc.local
endif
