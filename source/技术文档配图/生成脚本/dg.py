"""Small helpers for drawing block diagrams / flowcharts with matplotlib."""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm
from matplotlib.patches import FancyBboxPatch, Polygon, FancyArrowPatch, Rectangle

fm.fontManager.addfont('/Users/sherlockdarwin/Library/Fonts/AlibabaPuHuiTi-3-55-Regular.ttf')
plt.rcParams['font.family'] = ['Alibaba PuHuiTi 3.0']
plt.rcParams['axes.unicode_minus'] = False

# palette (soft fills, dark edges)
C = dict(
    sens='#E3F2FD', fpga='#FFF3E0', fpgabg='#FFFBF3', act='#E8F5E9', mcu='#F3E5F5',
    gray='#F5F5F5', yellow='#FFF9C4', red='#FFEBEE', blue='#E1F5FE', edge='#37474F',
    arrow='#455A64', accent='#E65100', green='#2E7D32', purple='#6A1B9A', blued='#1565C0')


def canvas(w, h, scale=0.62):
    fig = plt.figure(figsize=(w * scale, h * scale))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, w)
    ax.set_ylim(0, h)
    ax.set_aspect('equal')
    ax.axis('off')
    return fig, ax


def box(ax, x, y, w, h, text, fc='#FFFFFF', ec=None, fs=10, bold=False, ls='-', lw=1.2,
        r=0.12, tc='#212121', va='center', ha='center', z=2):
    """x, y = lower-left corner."""
    ec = ec or C['edge']
    p = FancyBboxPatch((x, y), w, h, boxstyle=f'round,pad=0,rounding_size={r}',
                       fc=fc, ec=ec, lw=lw, ls=ls, zorder=z)
    ax.add_patch(p)
    if text:
        tx = x + w / 2 if ha == 'center' else x + 0.15
        ty = y + h / 2 if va == 'center' else y + h - 0.15
        ax.text(tx, ty, text, ha=ha, va=va, fontsize=fs, color=tc,
                fontweight='bold' if bold else 'normal', zorder=z + 1, linespacing=1.35)
    return (x, y, w, h)


def diamond(ax, cx, cy, w, h, text, fc=C['yellow'], fs=9):
    p = Polygon([(cx - w / 2, cy), (cx, cy + h / 2), (cx + w / 2, cy), (cx, cy - h / 2)],
                closed=True, fc=fc, ec=C['edge'], lw=1.2, zorder=2)
    ax.add_patch(p)
    ax.text(cx, cy, text, ha='center', va='center', fontsize=fs, zorder=3, linespacing=1.3)


def arrow(ax, p1, p2, text=None, color=None, lw=1.3, fs=8, style='-|>', ls='-', rad=0.0,
          toff=(0, 0.12), tha='center', tc=None, z=4, ms=11):
    color = color or C['arrow']
    a = FancyArrowPatch(p1, p2, arrowstyle=style, mutation_scale=ms, color=color, lw=lw,
                        ls=ls, connectionstyle=f'arc3,rad={rad}', zorder=z,
                        shrinkA=0, shrinkB=0)
    ax.add_patch(a)
    if text:
        mx = (p1[0] + p2[0]) / 2 + toff[0]
        my = (p1[1] + p2[1]) / 2 + toff[1]
        ax.text(mx, my, text, ha=tha, va='bottom', fontsize=fs, color=tc or '#37474F', zorder=z + 1,
                bbox=dict(fc='white', ec='none', pad=0.6, alpha=0.85), linespacing=1.2)


def poly(ax, pts, text=None, color=None, lw=1.3, fs=8, tpos=None, style='-|>', ls='-', tha='center'):
    """Orthogonal polyline arrow through pts; arrow head at the end."""
    color = color or C['arrow']
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    ax.plot(xs[:-1], ys[:-1], color=color, lw=lw, ls=ls, zorder=4, solid_capstyle='butt')
    arrow(ax, pts[-2], pts[-1], color=color, lw=lw, style=style, ls=ls)
    if text and tpos:
        ax.text(tpos[0], tpos[1], text, ha=tha, va='center', fontsize=fs, color='#37474F', zorder=6,
                bbox=dict(fc='white', ec='none', pad=0.6, alpha=0.85))


def label(ax, x, y, text, fs=9, color='#37474F', ha='center', va='center', bold=False, z=6, **kw):
    ax.text(x, y, text, ha=ha, va=va, fontsize=fs, color=color, zorder=z,
            fontweight='bold' if bold else 'normal', linespacing=1.3, **kw)


def save(fig, path, dpi=220):
    fig.savefig(path, dpi=dpi, facecolor='white')
    plt.close(fig)
